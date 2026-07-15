package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

const defaultLinearAPIURL = "https://api.linear.app/graphql"

type LinearClient struct {
	token      string
	apiURL     string
	httpClient *http.Client
}

type LinearCreateIssueInput struct {
	Title       string   `json:"title"`
	Description string   `json:"description,omitempty"`
	TeamID      string   `json:"teamId"`
	ProjectID   string   `json:"projectId,omitempty"`
	AssigneeID  string   `json:"assigneeId,omitempty"`
	LabelIDs    []string `json:"labelIds,omitempty"`
}

type LinearCreatedIssue struct {
	ID         string         `json:"id"`
	Identifier string         `json:"identifier"`
	Title      string         `json:"title"`
	URL        string         `json:"url"`
	Project    *LinearProject `json:"project,omitempty"`
	Assignee   *LinearUser    `json:"assignee,omitempty"`
	Creator    *LinearUser    `json:"creator,omitempty"`
	CreatedAt  string         `json:"createdAt,omitempty"`
	UpdatedAt  string         `json:"updatedAt,omitempty"`
}

type LinearProject struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type LinearUser struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

func NewLinearClient(cfg *Config) *LinearClient {
	apiURL := strings.TrimSpace(cfg.LinearAPIURL)
	if apiURL == "" {
		apiURL = defaultLinearAPIURL
	}
	return &LinearClient{
		token:  strings.TrimSpace(cfg.LinearAPIToken),
		apiURL: apiURL,
		httpClient: &http.Client{
			Timeout: 20 * time.Second,
		},
	}
}

func (c *LinearClient) Enabled() bool {
	return c != nil && strings.TrimSpace(c.token) != ""
}

func (c *LinearClient) CreateIssue(ctx context.Context, input LinearCreateIssueInput) (*LinearCreatedIssue, error) {
	if !c.Enabled() {
		return nil, fmt.Errorf("linear api token is not configured")
	}
	input.Title = strings.TrimSpace(input.Title)
	input.TeamID = strings.TrimSpace(input.TeamID)
	input.ProjectID = strings.TrimSpace(input.ProjectID)
	input.AssigneeID = strings.TrimSpace(input.AssigneeID)
	input.Description = strings.TrimSpace(input.Description)
	if input.Title == "" || input.TeamID == "" {
		return nil, fmt.Errorf("title and teamId are required")
	}

	variables := map[string]any{
		"input": input,
	}
	query := `
mutation CreateIssue($input: IssueCreateInput!) {
  issueCreate(input: $input) {
    success
    issue {
      id
      identifier
      title
      url
      project { id name }
      assignee { id name }
      creator { id name }
      createdAt
      updatedAt
    }
  }
}`

	var resp struct {
		Data struct {
			IssueCreate struct {
				Success bool                `json:"success"`
				Issue   *LinearCreatedIssue `json:"issue"`
			} `json:"issueCreate"`
		} `json:"data"`
		Errors []struct {
			Message string `json:"message"`
		} `json:"errors"`
	}
	if err := c.doGraphQL(ctx, query, variables, &resp); err != nil {
		return nil, err
	}
	if len(resp.Errors) > 0 {
		messages := make([]string, 0, len(resp.Errors))
		for _, item := range resp.Errors {
			if strings.TrimSpace(item.Message) != "" {
				messages = append(messages, item.Message)
			}
		}
		return nil, fmt.Errorf("linear graphql error: %s", strings.Join(messages, "; "))
	}
	if !resp.Data.IssueCreate.Success || resp.Data.IssueCreate.Issue == nil {
		return nil, fmt.Errorf("linear issueCreate did not return an issue")
	}
	return resp.Data.IssueCreate.Issue, nil
}

func (c *LinearClient) doGraphQL(ctx context.Context, query string, variables map[string]any, target any) error {
	body, err := json.Marshal(map[string]any{
		"query":     query,
		"variables": variables,
	})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.apiURL, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", c.token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "TicTracker-MCP/1.0")

	res, err := c.httpClient.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	data, readErr := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if readErr != nil {
		return readErr
	}
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return fmt.Errorf("linear http %d: %s", res.StatusCode, strings.TrimSpace(string(data)))
	}
	if err := json.Unmarshal(data, target); err != nil {
		return fmt.Errorf("decode linear response: %w", err)
	}
	return nil
}
