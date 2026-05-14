import SwiftUI

private enum SettingsTab: Hashable {
    case department
    case general
    case rss
    case issueTracker
    case linear
    case jira
    case feishu
    case ai
    case data
    case sync
    case about
}

struct SettingsView: View {
    @Bindable var store: DataStore
    @State private var selectedTab: SettingsTab = .department

    var body: some View {
        tabContent
            .frame(minWidth: 560, minHeight: 420)
            .onDisappear {
                NSApp.setActivationPolicy(.accessory)
            }
    }

    @ViewBuilder
    private var tabContent: some View {
        let tabs = TabView(selection: $selectedTab) {
            DepartmentTab(store: store)
                .tabItem { Label("项目", systemImage: "building.2") }
                .tag(SettingsTab.department)
            GeneralTab(store: store)
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            RSSTab(store: store)
                .tabItem { Label("RSS", systemImage: "dot.radiowaves.up.forward") }
                .tag(SettingsTab.rss)
            IssueTrackerTab(store: store)
                .tabItem { Label("问题追踪", systemImage: "ladybug.fill") }
                .tag(SettingsTab.issueTracker)
            FeishuBotTab(store: store, isActive: selectedTab == .feishu)
                .tabItem { Label("飞书 Bot", systemImage: "paperplane.fill") }
                .tag(SettingsTab.feishu)
            AITab(store: store, isActive: selectedTab == .ai)
                .tabItem { Label("AI", systemImage: "sparkles") }
                .tag(SettingsTab.ai)
            DataTab(store: store)
                .tabItem { Label("数据", systemImage: "externaldrive") }
                .tag(SettingsTab.data)
            SyncTab(store: store, isActive: selectedTab == .sync)
                .tabItem { Label("同步", systemImage: "arrow.triangle.2.circlepath.icloud") }
                .tag(SettingsTab.sync)
            LinearTab(store: store, isActive: selectedTab == .linear)
                .tabItem { Label("Linear 入口", systemImage: "arrow.triangle.branch") }
                .tag(SettingsTab.linear)
            JiraTab(store: store, isActive: selectedTab == .jira)
                .tabItem { Label("Jira 入口", systemImage: "server.rack") }
                .tag(SettingsTab.jira)
            AboutTab()
                .tabItem { Label("关于", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        if #available(macOS 15, *) {
            tabs.tabViewStyle(.sidebarAdaptable)
        } else {
            tabs
        }
    }
}
