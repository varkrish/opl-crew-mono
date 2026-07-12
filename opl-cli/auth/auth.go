package auth

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os/exec"
	"runtime"
	"strings"
	"time"

	"github.com/varkrish/opl-cli-go/config"
)

func openBrowser(url string) {
	var err error
	switch runtime.GOOS {
	case "linux":
		err = exec.Command("xdg-open", url).Start()
	case "windows":
		err = exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start()
	case "darwin":
		err = exec.Command("open", url).Start()
	default:
		err = fmt.Errorf("unsupported platform")
	}
	if err != nil {
		fmt.Printf("Failed to open browser, please navigate to: %s\n", url)
	}
}

func Login(authURL string, clientID string) error {
	tokenChan := make(chan string, 1)
	errChan := make(chan error, 1)

	mux := http.NewServeMux()

	mux.HandleFunc("/callback", func(w http.ResponseWriter, r *http.Request) {
		html := `
		<html>
		<body>
		<script>
		if(window.location.hash) {
			fetch('/capture', {
				method: 'POST',
				headers: {'Content-Type': 'application/json'},
				body: JSON.stringify({hash: window.location.hash})
			}).then(() => {
				document.body.innerHTML = '<h2 style="font-family: sans-serif; color: #4CAF50;">Login successful! You can close this window and return to the CLI.</h2>';
			});
		} else {
			const urlParams = new URLSearchParams(window.location.search);
			const code = urlParams.get('code');
			if(code) {
				fetch('/capture', {
					method: 'POST',
					headers: {'Content-Type': 'application/json'},
					body: JSON.stringify({code: code})
				}).then(() => {
					document.body.innerHTML = '<h2 style="font-family: sans-serif; color: #4CAF50;">Login successful! You can close this window and return to the CLI.</h2>';
				});
			} else {
				document.body.innerHTML = '<h2 style="font-family: sans-serif; color: red;">Error: No token or code found in URL.</h2>';
			}
		}
		</script>
		</body>
		</html>
		`
		w.Header().Set("Content-Type", "text/html")
		w.Write([]byte(html))
	})

	mux.HandleFunc("/capture", func(w http.ResponseWriter, r *http.Request) {
		var data map[string]string
		if err := json.NewDecoder(r.Body).Decode(&data); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}

		if hashStr, ok := data["hash"]; ok {
			hashStr = strings.TrimPrefix(hashStr, "#")
			params, _ := url.ParseQuery(hashStr)
			token := params.Get("access_token")
			if token == "" {
				token = params.Get("id_token")
			}
			tokenChan <- token
		} else if code, ok := data["code"]; ok {
			// Stub: If a code is returned, use it. In full PKCE, we exchange this.
			tokenChan <- code
		} else {
			errChan <- fmt.Errorf("no token or code captured")
		}

		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"status":"ok"}`))
	})

	server := &http.Server{Addr: "localhost:8080", Handler: mux}

	go func() {
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			errChan <- err
		}
	}()

	params := url.Values{}
	params.Add("client_id", clientID)
	params.Add("redirect_uri", "http://localhost:8080/callback")
	params.Add("response_type", "token id_token")
	params.Add("scope", "openid profile email")
	params.Add("nonce", "12345")

	loginURL := fmt.Sprintf("%s?%s", authURL, params.Encode())
	fmt.Println("Opening browser to authenticate...")
	openBrowser(loginURL)

	fmt.Println("Waiting for authentication callback on port 8080...")

	var token string
	select {
	case token = <-tokenChan:
		// Success
	case err := <-errChan:
		return err
	case <-time.After(5 * time.Minute):
		return fmt.Errorf("authentication timed out")
	}

	// Shut down server
	server.Shutdown(context.Background())

	if token != "" {
		cfg := config.LoadConfig()
		env := config.GetActiveEnv()
		env.Token = token
		cfg.Environments[cfg.CurrentEnv] = env
		config.SaveConfig(cfg)
		fmt.Println("Successfully authenticated and saved token!")
		return nil
	}

	return fmt.Errorf("failed to retrieve token")
}
