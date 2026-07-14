package main

import (
	"encoding/json"
	"fmt"
	"os"
	"syscall"

	"github.com/spf13/cobra"
	"github.com/varkrish/opl-cli-go/auth"
	"github.com/varkrish/opl-cli-go/client"
	"github.com/varkrish/opl-cli-go/config"
	"golang.org/x/term"
)

var rootCmd = &cobra.Command{
	Use:   "opl-cli",
	Short: "OPL Studio Command Line Interface",
}

var envCmd = &cobra.Command{
	Use:   "env",
	Short: "Manage CLI environments",
	Run: func(cmd *cobra.Command, args []string) {
		fmt.Println("The 'env' command requires a specific action. Here are your options:")
		fmt.Println("  👉 opl-cli env list - See your active environments")
		fmt.Println("  👉 opl-cli env add <name> --url <url> - Add a new backend environment")
		fmt.Println("  👉 opl-cli env use <name> - Switch to a different environment")
		fmt.Println("\nRun opl-cli env --help for a full list of commands.")
	},
}

var authCmd = &cobra.Command{
	Use:   "auth",
	Short: "Manage authentication",
}

func init() {
	// ENV COMMANDS
	var url string
	var insecure bool

	addCmd := &cobra.Command{
		Use:   "add [name]",
		Short: "Add a new environment",
		Args:  cobra.ExactArgs(1),
		Run: func(cmd *cobra.Command, args []string) {
			name := args[0]
			cfg := config.LoadConfig()
			cfg.Environments[name] = config.EnvironmentConfig{
				URL:      url,
				Insecure: insecure,
			}
			if err := config.SaveConfig(cfg); err != nil {
				fmt.Printf("❌ Failed to save config: %v\n", err)
				return
			}
			fmt.Printf("✅ Added environment '%s' -> %s\n", name, url)
		},
	}
	addCmd.Flags().StringVar(&url, "url", "", "Backend URL")
	addCmd.MarkFlagRequired("url")
	addCmd.Flags().BoolVar(&insecure, "insecure", false, "Ignore HTTPS warnings")

	useCmd := &cobra.Command{
		Use:   "use [name]",
		Short: "Switch to a different environment",
		Args:  cobra.ExactArgs(1),
		Run: func(cmd *cobra.Command, args []string) {
			name := args[0]
			cfg := config.LoadConfig()
			if _, exists := cfg.Environments[name]; !exists {
				fmt.Printf("❌ Environment '%s' not found.\n", name)
				os.Exit(1)
			}
			cfg.CurrentEnv = name
			if err := config.SaveConfig(cfg); err != nil {
				fmt.Printf("❌ Failed to save config: %v\n", err)
				return
			}
			fmt.Printf("✅ Switched to environment '%s'\n", name)
		},
	}

	listCmd := &cobra.Command{
		Use:   "list",
		Short: "List all configured environments",
		Run: func(cmd *cobra.Command, args []string) {
			cfg := config.LoadConfig()
			fmt.Printf("%-5s | %-15s | %-30s | %-10s | %-10s\n", "Active", "Name", "URL", "Insecure", "Has Token")
			fmt.Println("--------------------------------------------------------------------------------------")
			for name, env := range cfg.Environments {
				active := ""
				if name == cfg.CurrentEnv {
					active = "*"
				}
				hasToken := "No"
				if env.Token != "" {
					hasToken = "Yes"
				}
				fmt.Printf("%-5s | %-15s | %-30s | %-10v | %-10s\n", active, name, env.URL, env.Insecure, hasToken)
			}
		},
	}

	envCmd.AddCommand(addCmd, useCmd, listCmd)
	rootCmd.AddCommand(envCmd)

	// AUTH COMMANDS
	var authURL string
	var clientID string

	loginCmd := &cobra.Command{
		Use:   "login",
		Short: "Login via Browser OAuth redirect",
		Run: func(cmd *cobra.Command, args []string) {
			if err := auth.Login(authURL, clientID); err != nil {
				fmt.Printf("❌ Login failed: %v\n", err)
				os.Exit(1)
			}
		},
	}
	loginCmd.Flags().StringVar(&authURL, "auth-url", "http://localhost:8180/realms/opl-crew/protocol/openid-connect/auth", "Keycloak Authorization URL")
	loginCmd.Flags().StringVar(&clientID, "client-id", "opl-studio", "OAuth Client ID")

	authCmd.AddCommand(loginCmd)
	rootCmd.AddCommand(authCmd)

	// HEALTH COMMAND
	healthCmd := &cobra.Command{
		Use:   "health",
		Short: "Check the health of the currently active backend",
		Run: func(cmd *cobra.Command, args []string) {
			c := client.NewClient()
			resp, err := c.Health()
			if err != nil {
				fmt.Println("❌ Connection refused.")
				fmt.Printf("The CLI could not connect to the backend server at %s.\n\n", c.BaseURL)
				fmt.Println("What to do:")
				fmt.Println("1. Ensure your backend is running (e.g., using 'make compose-up' or 'make studio-run').")
				fmt.Println("2. Or, verify you are using the correct CLI environment by running 'opl-cli env list'.")
				os.Exit(1)
			}
			fmt.Println("✅ Backend is healthy!")
			fmt.Println(resp)
		},
	}
	rootCmd.AddCommand(healthCmd)

	// JOBS COMMAND
	jobsCmd := &cobra.Command{
		Use:   "jobs",
		Short: "Manage AI software development jobs",
	}

	jobsListCmd := &cobra.Command{
		Use:   "list",
		Short: "List recent AI software development jobs",
		Run: func(cmd *cobra.Command, args []string) {
			c := client.NewClient()
			jobs, err := c.ListJobs()
			if err != nil {
				if err.Error() == "unauthorized" {
					fmt.Println("❌ Unauthorized. Please run `opl-cli auth login` first.")
					os.Exit(1)
				}
				fmt.Println("❌ Connection refused or error occurred.")
				fmt.Printf("The CLI could not connect to the backend server at %s.\n\n", c.BaseURL)
				os.Exit(1)
			}

			fmt.Printf("%-36s | %-40s | %-10s | %-15s\n", "ID", "Vision", "Status", "Phase")
			fmt.Println("-----------------------------------------------------------------------------------------------------------")
			for _, job := range jobs {
				vision := job.Vision
				if len(vision) > 37 {
					vision = vision[:37] + "..."
				}
				fmt.Printf("%-36s | %-40s | %-10s | %-15s\n", job.ID, vision, job.Status, job.CurrentPhase)
			}
		},
	}

	var visionStr string
	var autoApprove bool
	var capsStr string

	jobsCreateCmd := &cobra.Command{
		Use:   "create",
		Short: "Create a new job",
		Run: func(cmd *cobra.Command, args []string) {
			c := client.NewClient()
			req := client.JobRequest{
				Vision:          visionStr,
				AutoApprovePlan: autoApprove,
			}
			if capsStr != "" {
				var caps map[string]interface{}
				if err := json.Unmarshal([]byte(capsStr), &caps); err != nil {
					// Fallback: assume the user provided a raw string profile
					caps = map[string]interface{}{
						"profile": capsStr,
					}
				}
				req.CapabilityProfile = caps
			}
			res, err := c.CreateJob(req)
			if err != nil {
				fmt.Printf("❌ Failed to create job: %v\n", err)
				os.Exit(1)
			}
			fmt.Printf("✅ Job created successfully! ID: %s\n", res.JobID)
		},
	}
	jobsCreateCmd.Flags().StringVar(&visionStr, "vision", "", "The vision/prompt for the job")
	jobsCreateCmd.MarkFlagRequired("vision")
	jobsCreateCmd.Flags().BoolVar(&autoApprove, "auto-approve", false, "Auto approve the plan")
	jobsCreateCmd.Flags().StringVar(&capsStr, "capabilities", "", "Capability profile JSON string")

	jobsCancelCmd := &cobra.Command{
		Use:   "cancel [job-id]",
		Short: "Cancel a running job",
		Args:  cobra.ExactArgs(1),
		Run: func(cmd *cobra.Command, args []string) {
			c := client.NewClient()
			if err := c.CancelJob(args[0]); err != nil {
				fmt.Printf("❌ Failed to cancel job: %v\n", err)
				os.Exit(1)
			}
			fmt.Println("✅ Job cancelled successfully.")
		},
	}

	jobsPlanCmd := &cobra.Command{
		Use:   "plan [job-id]",
		Short: "View the plan for a job",
		Args:  cobra.ExactArgs(1),
		Run: func(cmd *cobra.Command, args []string) {
			c := client.NewClient()
			plan, err := c.GetJobPlan(args[0])
			if err != nil {
				fmt.Printf("❌ Failed to get job plan: %v\n", err)
				os.Exit(1)
			}
			var obj interface{}
			if err := json.Unmarshal(plan, &obj); err == nil {
				b, _ := json.MarshalIndent(obj, "", "  ")
				fmt.Println(string(b))
			} else {
				fmt.Println(string(plan))
			}
		},
	}

	jobsFilesCmd := &cobra.Command{
		Use:   "files [job-id]",
		Short: "View the file tree for a job",
		Args:  cobra.ExactArgs(1),
		Run: func(cmd *cobra.Command, args []string) {
			c := client.NewClient()
			files, err := c.GetWorkspaceFiles(args[0])
			if err != nil {
				fmt.Printf("❌ Failed to get job files: %v\n", err)
				os.Exit(1)
			}
			fmt.Printf("%-50s | %-10s | %-20s\n", "Path", "Size", "Modified")
			fmt.Println("--------------------------------------------------------------------------------------")
			for _, f := range files {
				fmt.Printf("%-50s | %-10d | %-20s\n", f.Path, f.Size, f.Modified)
			}
		},
	}

	var streamLogs bool
	jobsLogsCmd := &cobra.Command{
		Use:   "logs [job-id]",
		Short: "View or stream execution logs for a job",
		Args:  cobra.ExactArgs(1),
		Run: func(cmd *cobra.Command, args []string) {
			c := client.NewClient()
			jobID := args[0]
			if streamLogs {
				err := c.StreamJobLogs(jobID, os.Stdout)
				if err != nil {
					fmt.Printf("❌ Failed to stream job logs: %v\n", err)
					os.Exit(1)
				}
			} else {
				logs, err := c.GetJobLogs(jobID)
				if err != nil {
					fmt.Printf("❌ Failed to get job logs: %v\n", err)
					os.Exit(1)
				}
				fmt.Print(string(logs))
			}
		},
	}
	jobsLogsCmd.Flags().BoolVar(&streamLogs, "stream", false, "Stream logs in real-time")

	jobsCmd.AddCommand(jobsListCmd, jobsCreateCmd, jobsCancelCmd, jobsPlanCmd, jobsFilesCmd, jobsLogsCmd)
	rootCmd.AddCommand(jobsCmd)

	// SETTINGS COMMANDS
	settingsCmd := &cobra.Command{
		Use:   "settings",
		Short: "Manage your OPL settings (workflow, mcp, llm, jira, github)",
	}

	printJson := func(v interface{}) {
		b, _ := json.MarshalIndent(v, "", "  ")
		fmt.Println(string(b))
	}

	// settings workflow
	workflowCmd := &cobra.Command{
		Use:   "workflow",
		Short: "Manage workflow settings",
	}
	workflowCmd.AddCommand(&cobra.Command{
		Use:   "get",
		Short: "Get workflow settings",
		Run: func(cmd *cobra.Command, args []string) {
			c := client.NewClient()
			cfg, err := c.GetWorkflowConfig()
			if err != nil {
				fmt.Printf("❌ Error: %v\n", err)
				os.Exit(1)
			}
			printJson(cfg)
		},
	})
	workflowCmd.AddCommand(&cobra.Command{
		Use:   "delete",
		Short: "Reset workflow settings to defaults",
		Run: func(cmd *cobra.Command, args []string) {
			c := client.NewClient()
			err := c.DeleteWorkflowConfig()
			if err != nil {
				fmt.Printf("❌ Error: %v\n", err)
				os.Exit(1)
			}
			fmt.Println("✅ Workflow settings reset to defaults.")
		},
	})
	settingsCmd.AddCommand(workflowCmd)

	// settings mcp
	mcpCmd := &cobra.Command{
		Use:   "mcp",
		Short: "Manage MCP server configs",
	}
	mcpCmd.AddCommand(&cobra.Command{
		Use:   "list",
		Short: "List MCP server configs",
		Run: func(cmd *cobra.Command, args []string) {
			c := client.NewClient()
			cfgs, err := c.ListMcpConfigs()
			if err != nil {
				fmt.Printf("❌ Error: %v\n", err)
				os.Exit(1)
			}
			printJson(cfgs)
		},
	})
	mcpCmd.AddCommand(&cobra.Command{
		Use:   "delete [server-name]",
		Short: "Delete an MCP server config",
		Args:  cobra.ExactArgs(1),
		Run: func(cmd *cobra.Command, args []string) {
			c := client.NewClient()
			err := c.DeleteMcpConfig(args[0])
			if err != nil {
				fmt.Printf("❌ Error: %v\n", err)
				os.Exit(1)
			}
			fmt.Printf("✅ MCP config '%s' deleted.\n", args[0])
		},
	})
	settingsCmd.AddCommand(mcpCmd)

	// settings llm
	llmCmd := &cobra.Command{
		Use:   "llm",
		Short: "Manage LLM settings",
	}
	llmCmd.AddCommand(&cobra.Command{
		Use:   "get",
		Short: "Get LLM settings",
		Run: func(cmd *cobra.Command, args []string) {
			c := client.NewClient()
			cfg, err := c.GetLLMConfig()
			if err != nil {
				fmt.Printf("❌ Error: %v\n", err)
				os.Exit(1)
			}
			printJson(cfg)
		},
	})

	var llmBaseUrl, modelManager, modelWorker, modelReviewer string
	llmSetCmd := &cobra.Command{
		Use:   "set",
		Short: "Set LLM settings",
		Run: func(cmd *cobra.Command, args []string) {
			fmt.Print("Enter API Key: ")
			bytePassword, err := term.ReadPassword(int(syscall.Stdin))
			if err != nil {
				fmt.Printf("\n❌ Error reading API key: %v\n", err)
				os.Exit(1)
			}
			fmt.Println()
			llmApiKey := string(bytePassword)
			if llmApiKey == "" {
				fmt.Println("❌ Error: API key cannot be empty.")
				os.Exit(1)
			}

			cfg := &client.LLMConfig{
				ApiBaseUrl:    llmBaseUrl,
				ApiKey:        llmApiKey,
				ModelManager:  modelManager,
				ModelWorker:   modelWorker,
				ModelReviewer: modelReviewer,
			}
			c := client.NewClient()
			err = c.SaveLLMConfig(cfg)
			if err != nil {
				fmt.Printf("❌ Error saving config: %v\n", err)
				os.Exit(1)
			}
			fmt.Println("✅ LLM settings saved.")
		},
	}
	llmSetCmd.Flags().StringVar(&llmBaseUrl, "api-base-url", "", "API Base URL (Required)")
	llmSetCmd.Flags().StringVar(&modelManager, "model-manager", "gpt-4o-mini", "Model Manager")
	llmSetCmd.Flags().StringVar(&modelWorker, "model-worker", "gpt-4o-mini", "Model Worker")
	llmSetCmd.Flags().StringVar(&modelReviewer, "model-reviewer", "gpt-4o-mini", "Model Reviewer")
	llmSetCmd.MarkFlagRequired("api-base-url")
	llmCmd.AddCommand(llmSetCmd)
	llmCmd.AddCommand(&cobra.Command{
		Use:   "delete",
		Short: "Delete LLM settings",
		Run: func(cmd *cobra.Command, args []string) {
			c := client.NewClient()
			err := c.DeleteLLMConfig()
			if err != nil {
				fmt.Printf("❌ Error: %v\n", err)
				os.Exit(1)
			}
			fmt.Println("✅ LLM settings deleted.")
		},
	})
	settingsCmd.AddCommand(llmCmd)

	// settings jira
	jiraCmd := &cobra.Command{
		Use:   "jira",
		Short: "Manage Jira credentials",
	}
	jiraCmd.AddCommand(&cobra.Command{
		Use:   "get",
		Short: "Get Jira credentials status",
		Run: func(cmd *cobra.Command, args []string) {
			c := client.NewClient()
			cfg, err := c.GetJiraConfig()
			if err != nil {
				fmt.Printf("❌ Error: %v\n", err)
				os.Exit(1)
			}
			printJson(cfg)
		},
	})
	jiraCmd.AddCommand(&cobra.Command{
		Use:   "delete",
		Short: "Delete Jira credentials",
		Run: func(cmd *cobra.Command, args []string) {
			c := client.NewClient()
			err := c.DeleteJiraConfig()
			if err != nil {
				fmt.Printf("❌ Error: %v\n", err)
				os.Exit(1)
			}
			fmt.Println("✅ Jira credentials deleted.")
		},
	})
	settingsCmd.AddCommand(jiraCmd)

	// settings github
	githubCmd := &cobra.Command{
		Use:   "github",
		Short: "Manage GitHub PAT",
	}
	githubCmd.AddCommand(&cobra.Command{
		Use:   "get",
		Short: "Get GitHub PAT status",
		Run: func(cmd *cobra.Command, args []string) {
			c := client.NewClient()
			cfg, err := c.GetGithubConfig()
			if err != nil {
				fmt.Printf("❌ Error: %v\n", err)
				os.Exit(1)
			}
			printJson(cfg)
		},
	})
	githubCmd.AddCommand(&cobra.Command{
		Use:   "delete",
		Short: "Delete GitHub PAT",
		Run: func(cmd *cobra.Command, args []string) {
			c := client.NewClient()
			err := c.DeleteGithubConfig()
			if err != nil {
				fmt.Printf("❌ Error: %v\n", err)
				os.Exit(1)
			}
			fmt.Println("✅ GitHub PAT deleted.")
		},
	})
	settingsCmd.AddCommand(githubCmd)

	rootCmd.AddCommand(settingsCmd)
}

func main() {
	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}
