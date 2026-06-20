package main

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
	"github.com/varkrish/opl-cli-go/auth"
	"github.com/varkrish/opl-cli-go/client"
	"github.com/varkrish/opl-cli-go/config"
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
	loginCmd.Flags().StringVar(&authURL, "auth-url", "http://localhost:8080/auth/realms/master/protocol/openid-connect/auth", "Keycloak Authorization URL")
	loginCmd.Flags().StringVar(&clientID, "client-id", "opl-cli", "OAuth Client ID")

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
				fmt.Println("What to do:")
				fmt.Println("1. Ensure your backend is running (e.g., using 'make compose-up' or 'make studio-run').")
				fmt.Println("2. Or, verify you are using the correct CLI environment by running 'opl-cli env list'.")
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
	rootCmd.AddCommand(jobsCmd)
}

func main() {
	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}
