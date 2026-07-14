package client

import (
	"bufio"
	"bytes"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/varkrish/opl-cli-go/config"
)

type Client struct {
	HTTPClient *http.Client
	BaseURL    string
	Token      string
}

func NewClient() *Client {
	env := config.GetActiveEnv()
	tr := &http.Transport{
		TLSClientConfig: &tls.Config{InsecureSkipVerify: env.Insecure},
	}
	httpClient := &http.Client{
		Transport: tr,
		Timeout:   10 * time.Second,
	}

	return &Client{
		HTTPClient: httpClient,
		BaseURL:    env.URL,
		Token:      env.Token,
	}
}

func (c *Client) request(method, path string) ([]byte, int, error) {
	req, err := http.NewRequest(method, c.BaseURL+path, nil)
	if err != nil {
		return nil, 0, err
	}

	if c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}

	resp, err := c.HTTPClient.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	return body, resp.StatusCode, err
}

func (c *Client) Health() (string, error) {
	body, code, err := c.request("GET", "/health")
	if err != nil {
		return "", err
	}
	if code != 200 {
		return "", fmt.Errorf("backend returned status %d", code)
	}
	return string(body), nil
}

type Job struct {
	ID           string `json:"id"`
	Vision       string `json:"vision"`
	Status       string `json:"status"`
	CurrentPhase string `json:"current_phase"`
}

type JobsResponse struct {
	Jobs []Job `json:"jobs"`
}

func (c *Client) ListJobs() ([]Job, error) {
	body, code, err := c.request("GET", "/api/jobs")
	if err != nil {
		return nil, err
	}
	if code == 401 {
		return nil, fmt.Errorf("unauthorized")
	}
	if code != 200 {
		return nil, fmt.Errorf("backend returned status %d", code)
	}

	var resp []Job
	if err := json.Unmarshal(body, &resp); err == nil {
		return resp, nil
	}

	var objResp JobsResponse
	if err := json.Unmarshal(body, &objResp); err == nil {
		return objResp.Jobs, nil
	}

	return nil, fmt.Errorf("failed to parse jobs response")
}

type JobRequest struct {
	Vision            string                 `json:"vision"`
	Backend           string                 `json:"backend,omitempty"`
	AutoApprovePlan   bool                   `json:"auto_approve_plan"`
	CapabilityProfile map[string]interface{} `json:"capability_profile,omitempty"`
}

type JobCreateResponse struct {
	JobID       string `json:"job_id"`
	Status      string `json:"status"`
	Documents   int    `json:"documents"`
	GithubRepos int    `json:"github_repos"`
}

func (c *Client) CreateJob(req JobRequest) (*JobCreateResponse, error) {
	body, err := json.Marshal(req)
	if err != nil {
		return nil, err
	}

	respBody, status, err := c.requestBody("POST", "/api/jobs", body)
	if err != nil {
		return nil, err
	}
	if status >= 400 {
		return nil, fmt.Errorf("API error (%d): %s", status, string(respBody))
	}

	var res JobCreateResponse
	if err := json.Unmarshal(respBody, &res); err != nil {
		return nil, err
	}
	return &res, nil
}

func (c *Client) CancelJob(jobID string) error {
	respBody, status, err := c.requestBody("POST", fmt.Sprintf("/api/jobs/%s/cancel", jobID), nil)
	if err != nil {
		return err
	}
	if status >= 400 {
		return fmt.Errorf("API error (%d): %s", status, string(respBody))
	}
	return nil
}

func (c *Client) GetJobLogs(jobID string) ([]byte, error) {
	respBody, status, err := c.requestBody("GET", fmt.Sprintf("/api/jobs/%s/logs", jobID), nil)
	if err != nil {
		return nil, err
	}
	if status >= 400 {
		return nil, fmt.Errorf("API error (%d): %s", status, string(respBody))
	}
	return respBody, nil
}

func (c *Client) StreamJobLogs(jobID string, out io.Writer) error {
	req, err := http.NewRequest("GET", fmt.Sprintf("%s/api/jobs/%s/logs/stream", c.BaseURL, jobID), nil)
	if err != nil {
		return err
	}
	if c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}

	resp, err := c.HTTPClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("backend returned status %d: %s", resp.StatusCode, string(body))
	}

	reader := bufio.NewReader(resp.Body)
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			if err == io.EOF {
				break
			}
			return err
		}

		if strings.HasPrefix(line, "data: ") {
			data := strings.TrimPrefix(line, "data: ")
			data = strings.TrimSpace(data)
			
			var unescaped string
			if err := json.Unmarshal([]byte(data), &unescaped); err == nil {
				fmt.Fprint(out, unescaped)
			} else {
				fmt.Fprintln(out, data)
			}
		}
	}
	return nil
}

func (c *Client) GetJobPlan(jobID string) ([]byte, error) {
	respBody, status, err := c.requestBody("GET", fmt.Sprintf("/api/jobs/%s/plan", jobID), nil)
	if err != nil {
		return nil, err
	}
	if status >= 400 {
		return nil, fmt.Errorf("API error (%d): %s", status, string(respBody))
	}
	return respBody, nil
}

type WorkspaceFile struct {
	Path     string `json:"path"`
	Size     int64  `json:"size"`
	Modified string `json:"modified"`
}

func (c *Client) GetWorkspaceFiles(jobID string) ([]WorkspaceFile, error) {
	respBody, status, err := c.requestBody("GET", fmt.Sprintf("/api/workspace/files?job_id=%s", jobID), nil)
	if err != nil {
		return nil, err
	}
	if status >= 400 {
		return nil, fmt.Errorf("API error (%d): %s", status, string(respBody))
	}

	var payload struct {
		Files     []WorkspaceFile `json:"files"`
		Workspace string          `json:"workspace"`
	}
	if err := json.Unmarshal(respBody, &payload); err != nil {
		return nil, err
	}
	return payload.Files, nil
}

func (c *Client) requestBody(method, path string, body []byte) ([]byte, int, error) {
	var req *http.Request
	var err error

	if body != nil {
		req, err = http.NewRequest(method, c.BaseURL+path, bytes.NewBuffer(body))
		req.Header.Set("Content-Type", "application/json")
	} else {
		req, err = http.NewRequest(method, c.BaseURL+path, nil)
	}

	if err != nil {
		return nil, 0, err
	}

	if c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}

	resp, err := c.HTTPClient.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	return respBody, resp.StatusCode, err
}

// ---------------------------------------------------------------------------
// Workflow Config
// ---------------------------------------------------------------------------

type WorkflowConfig struct {
	Configured                   bool   `json:"configured"`
	PlanReviewEnabled            bool   `json:"plan_review_enabled"`
	SolutioningEnabled           bool   `json:"solutioning_enabled"`
	SolutioningMode              string `json:"solutioning_mode"`
	SolutioningMaxPasses         int    `json:"solutioning_max_passes"`
	SolutioningMaxGithubSearches int    `json:"solutioning_max_github_searches"`
	AutoApprovePlan              bool   `json:"auto_approve_plan"`
	TldrEnabled                  bool   `json:"tldr_enabled"`
	TldrMaxChars                 int    `json:"tldr_max_chars"`
	TldrIncludeStructure         bool   `json:"tldr_include_structure"`
	TldrMinCompletedFiles        int    `json:"tldr_min_completed_files"`
	ParallelFileWorkers          int    `json:"parallel_file_workers"`
	UpdatedAt                    string `json:"updated_at,omitempty"`
}

func (c *Client) GetWorkflowConfig() (*WorkflowConfig, error) {
	body, code, err := c.request("GET", "/api/workflow/config")
	if err != nil {
		return nil, err
	}
	if code != 200 {
		return nil, fmt.Errorf("backend returned status %d: %s", code, string(body))
	}

	var resp WorkflowConfig
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, err
	}
	return &resp, nil
}

func (c *Client) SaveWorkflowConfig(cfg *WorkflowConfig) error {
	data, _ := json.Marshal(cfg)
	body, code, err := c.requestBody("POST", "/api/workflow/config", data)
	if err != nil {
		return err
	}
	if code != 201 && code != 200 {
		return fmt.Errorf("backend returned status %d: %s", code, string(body))
	}
	return nil
}

func (c *Client) DeleteWorkflowConfig() error {
	body, code, err := c.request("DELETE", "/api/workflow/config")
	if err != nil {
		return err
	}
	if code != 200 {
		return fmt.Errorf("backend returned status %d: %s", code, string(body))
	}
	return nil
}

// ---------------------------------------------------------------------------
// MCP Config
// ---------------------------------------------------------------------------

type McpConfig struct {
	ServerName    string            `json:"server_name"`
	TargetAgent   string            `json:"target_agent"`
	TransportType string            `json:"transport_type"`
	Command       string            `json:"command,omitempty"`
	Args          []string          `json:"args,omitempty"`
	URL           string            `json:"url,omitempty"`
	Env           map[string]string `json:"env,omitempty"`
	Tools         []string          `json:"tools,omitempty"`
	UpdatedAt     string            `json:"updated_at,omitempty"`
}

func (c *Client) ListMcpConfigs() ([]McpConfig, error) {
	body, code, err := c.request("GET", "/api/mcp/configs")
	if err != nil {
		return nil, err
	}
	if code != 200 {
		return nil, fmt.Errorf("backend returned status %d: %s", code, string(body))
	}

	var resp []McpConfig
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, err
	}
	return resp, nil
}

func (c *Client) SaveMcpConfig(cfg *McpConfig) error {
	data, _ := json.Marshal(cfg)
	body, code, err := c.requestBody("POST", "/api/mcp/configs", data)
	if err != nil {
		return err
	}
	if code != 201 && code != 200 {
		return fmt.Errorf("backend returned status %d: %s", code, string(body))
	}
	return nil
}

func (c *Client) DeleteMcpConfig(serverName string) error {
	body, code, err := c.request("DELETE", "/api/mcp/configs/"+serverName)
	if err != nil {
		return err
	}
	if code != 200 {
		return fmt.Errorf("backend returned status %d: %s", code, string(body))
	}
	return nil
}

// ---------------------------------------------------------------------------
// LLM Config
// ---------------------------------------------------------------------------

type LLMConfig struct {
	Configured     bool   `json:"configured,omitempty"`
	ApiBaseUrl     string `json:"api_base_url"`
	ApiKey         string `json:"api_key,omitempty"`
	ApiTokenMasked string `json:"api_token_masked,omitempty"`
	ModelManager   string `json:"model_manager,omitempty"`
	ModelWorker    string `json:"model_worker,omitempty"`
	ModelReviewer  string `json:"model_reviewer,omitempty"`
	UpdatedAt      string `json:"updated_at,omitempty"`
}

func (c *Client) GetLLMConfig() (*LLMConfig, error) {
	body, code, err := c.request("GET", "/api/llm/config")
	if err != nil {
		return nil, err
	}
	if code != 200 {
		return nil, fmt.Errorf("backend returned status %d: %s", code, string(body))
	}

	var resp LLMConfig
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, err
	}
	return &resp, nil
}

func (c *Client) SaveLLMConfig(cfg *LLMConfig) error {
	data, _ := json.Marshal(cfg)
	body, code, err := c.requestBody("POST", "/api/llm/config", data)
	if err != nil {
		return err
	}
	if code != 201 && code != 200 {
		return fmt.Errorf("backend returned status %d: %s", code, string(body))
	}
	return nil
}

func (c *Client) DeleteLLMConfig() error {
	body, code, err := c.request("DELETE", "/api/llm/config")
	if err != nil {
		return err
	}
	if code != 200 {
		return fmt.Errorf("backend returned status %d: %s", code, string(body))
	}
	return nil
}

// ---------------------------------------------------------------------------
// Jira Config
// ---------------------------------------------------------------------------

type JiraConfig struct {
	Configured     bool   `json:"configured,omitempty"`
	JiraBaseUrl    string `json:"jira_base_url,omitempty"`
	JiraEmail      string `json:"jira_email,omitempty"`
	ApiToken       string `json:"api_token,omitempty"`
	ApiTokenMasked string `json:"api_token_masked,omitempty"`
	UpdatedAt      string `json:"updated_at,omitempty"`
}

func (c *Client) GetJiraConfig() (*JiraConfig, error) {
	body, code, err := c.request("GET", "/api/jira/config")
	if err != nil {
		return nil, err
	}
	if code != 200 {
		return nil, fmt.Errorf("backend returned status %d: %s", code, string(body))
	}

	var resp JiraConfig
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, err
	}
	return &resp, nil
}

func (c *Client) SaveJiraConfig(cfg *JiraConfig) error {
	data, _ := json.Marshal(cfg)
	body, code, err := c.requestBody("POST", "/api/jira/config", data)
	if err != nil {
		return err
	}
	if code != 201 && code != 200 {
		return fmt.Errorf("backend returned status %d: %s", code, string(body))
	}
	return nil
}

func (c *Client) DeleteJiraConfig() error {
	body, code, err := c.request("DELETE", "/api/jira/config")
	if err != nil {
		return err
	}
	if code != 200 {
		return fmt.Errorf("backend returned status %d: %s", code, string(body))
	}
	return nil
}

// ---------------------------------------------------------------------------
// GitHub Config
// ---------------------------------------------------------------------------

type GitHubConfig struct {
	Configured     bool   `json:"configured,omitempty"`
	GithubUsername string `json:"github_username,omitempty"`
	ApiToken       string `json:"api_token,omitempty"`
	ApiTokenMasked string `json:"api_token_masked,omitempty"`
	UpdatedAt      string `json:"updated_at,omitempty"`
}

func (c *Client) GetGithubConfig() (*GitHubConfig, error) {
	body, code, err := c.request("GET", "/api/github/config")
	if err != nil {
		return nil, err
	}
	if code != 200 {
		return nil, fmt.Errorf("backend returned status %d: %s", code, string(body))
	}

	var resp GitHubConfig
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, err
	}
	return &resp, nil
}

func (c *Client) SaveGithubConfig(cfg *GitHubConfig) error {
	data, _ := json.Marshal(cfg)
	body, code, err := c.requestBody("POST", "/api/github/config", data)
	if err != nil {
		return err
	}
	if code != 201 && code != 200 {
		return fmt.Errorf("backend returned status %d: %s", code, string(body))
	}
	return nil
}

func (c *Client) DeleteGithubConfig() error {
	body, code, err := c.request("DELETE", "/api/github/config")
	if err != nil {
		return err
	}
	if code != 200 {
		return fmt.Errorf("backend returned status %d: %s", code, string(body))
	}
	return nil
}
