import axios from 'axios'

export const API_BASE = '/api/v1'

export const httpClient = axios.create({
  baseURL: '',
  timeout: 30000
})

httpClient.interceptors.request.use((config) => {
  const token = localStorage.getItem('token')
  if (token) {
    config.headers.Authorization = `Bearer ${token}`
  }
  return config
})

httpClient.interceptors.response.use(
  (response) => response,
  (error) => {
    if (error.response?.status === 401) {
      localStorage.removeItem('token')
      window.history.replaceState(null, '', `${window.location.pathname}${window.location.search}`)
      window.location.reload()
    }
    return Promise.reject(error)
  }
)
