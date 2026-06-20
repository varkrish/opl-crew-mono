package client

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
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
