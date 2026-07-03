package session

import "testing"

func TestIsEphemeralCwd(t *testing.T) {
	ephemeral := []string{
		"/Users/example/Library/Application Support/CodexBar/ClaudeProbe",
		"/Users/example/Library/Caches/whatever",
		"/Users/example/somewhere/ClaudeProbe",
	}
	for _, c := range ephemeral {
		if !IsEphemeralCwd(c) {
			t.Errorf("IsEphemeralCwd(%q) = false, quero true", c)
		}
	}
	real := []string{
		"/Users/example/Desktop/coding/personal/cutuque",
		"/Users/example/Desktop/coding/example-org/AcmeSecurity/.maestri/roles/x",
		"",
	}
	for _, c := range real {
		if IsEphemeralCwd(c) {
			t.Errorf("IsEphemeralCwd(%q) = true, quero false", c)
		}
	}
}
