package libclash

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeTemp(t *testing.T, name, content string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

// TestLoadAndMergeConfigBasic: YAML base + JSON patch (clashmi core_path_patch
// format) → patch keys overwrite base, non-patched keys survive.
func TestLoadAndMergeConfigBasic(t *testing.T) {
	base := writeTemp(t, "config.yaml", `
mixed-port: 7890
mode: rule
log-level: info
dns:
  enable: true
  enhanced-mode: fake-ip
`)
	patch := writeTemp(t, "patch.json", `{
  "mode": "global",
  "log-level": "debug"
}`)

	out, hp, err := loadAndMergeConfig(base, patch, "")
	if err != nil {
		t.Fatal(err)
	}
	if hp == nil {
		t.Fatal("expected http proxy info")
	}
	for _, want := range []string{"mode: global", "log-level: debug", "mixed-port: 7890", "enhanced-mode: fake-ip"} {
		if !strings.Contains(out, want) {
			t.Errorf("merged config missing %q\n---\n%s", want, out)
		}
	}
}

// TestOverwriteControlKeys: nested `overwrite: false` vetoes the whole patch
// block (base wins), while plain keys still merge.
func TestOverwriteControlKeys(t *testing.T) {
	base := writeTemp(t, "config.yaml", `
mode: rule
dns:
  enable: true
  nameserver: [1.1.1.1]
`)
	patch := writeTemp(t, "patch.json", `{
  "overwrite-mode": false,
  "mode": "global",
  "log-level": "warning",
  "dns": {"overwrite": false, "nameserver": ["8.8.8.8"]}
}`)

	out, _, err := loadAndMergeConfig(base, patch, "")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "mode: rule") {
		t.Errorf("overwrite-mode:false should keep base mode\n%s", out)
	}
	if strings.Contains(out, "8.8.8.8") {
		t.Errorf("overwrite:false should veto the patch dns block\n%s", out)
	}
	if !strings.Contains(out, "1.1.1.1") {
		t.Errorf("base dns should survive\n%s", out)
	}
	if !strings.Contains(out, "log-level: warning") {
		t.Errorf("plain keys should still merge\n%s", out)
	}
}

// TestOverwriteTrueReplaces: `overwrite-<key>: true` deletes the control key
// but keeps the target key, which then replaces the base value.
func TestOverwriteTrueReplaces(t *testing.T) {
	base := writeTemp(t, "config.yaml", "mode: rule\nlog-level: info\n")
	patch := writeTemp(t, "patch.json", `{"overwrite-mode": true, "mode": "global"}`)

	out, _, err := loadAndMergeConfig(base, patch, "")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "mode: global") {
		t.Errorf("overwrite-mode:true should replace mode\n%s", out)
	}
	if strings.Contains(out, "overwrite") {
		t.Errorf("control keys must not leak into output\n%s", out)
	}
}

// TestExtensionAppend: extension.rules / append-proxy-groups / rule-providers
// are appended without touching base entries.
func TestExtensionAppend(t *testing.T) {
	base := writeTemp(t, "config.yaml", `
rules:
  - DOMAIN-SUFFIX,google.com,Proxy
proxy-groups:
  - name: Proxy
    type: select
`)
	patch := writeTemp(t, "patch.json", `{
  "extension": {
    "append-rules": ["MATCH,Proxy"],
    "append-proxy-groups": [{"name": "Auto", "type": "url-test"}],
    "rule-providers": {"reject": {"type": "http", "url": "http://x"}}
  }
}`)

	out, _, err := loadAndMergeConfig(base, patch, "")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "DOMAIN-SUFFIX,google.com,Proxy") {
		t.Errorf("base rule lost\n%s", out)
	}
	if !strings.Contains(out, "MATCH,Proxy") {
		t.Errorf("appended rule missing\n%s", out)
	}
	if !strings.Contains(out, "url-test") {
		t.Errorf("appended proxy-group missing\n%s", out)
	}
	if !strings.Contains(out, "reject") {
		t.Errorf("rule-provider missing\n%s", out)
	}
}

// TestExtensionHTTPProxy: tun.http_proxy is surfaced via httpProxyInfo and the
// port falls back to mixed-port when unset.
func TestExtensionHTTPProxy(t *testing.T) {
	base := writeTemp(t, "config.yaml", "mixed-port: 7890\n")
	patch := writeTemp(t, "patch.json", `{
  "extension": {
    "tun": {"http_proxy": {"enable": true, "server_port": 7897,
      "bypass_domain": ["*.local"], "match_domain": ["*.example.com"]}}
  }
}`)

	_, hp, err := loadAndMergeConfig(base, patch, "")
	if err != nil {
		t.Fatal(err)
	}
	if !hp.Enable || hp.Port != 7897 || hp.Server != "127.0.0.1" {
		t.Errorf("http proxy info wrong: %+v", hp)
	}
	if len(hp.Bypass) != 1 || hp.Bypass[0] != "*.local" {
		t.Errorf("bypass wrong: %v", hp.Bypass)
	}
}

// TestHTTPProxyPortFallback: without an explicit port the merged config's
// mixed-port is used (clashmi ExtensionProvider contract).
func TestHTTPProxyPortFallback(t *testing.T) {
	base := writeTemp(t, "config.yaml", "mixed-port: 7890\n")
	patch := writeTemp(t, "patch.json", `{"extension": {"tun": {"http_proxy": {"enable": true}}}}`)

	_, hp, err := loadAndMergeConfig(base, patch, "")
	if err != nil {
		t.Fatal(err)
	}
	if hp.Port != 7890 {
		t.Errorf("expected fallback to mixed-port 7890, got %d", hp.Port)
	}
}

// TestPatchFinalOrder: the second patch (core_path_patch_final) wins over the
// first (core_path_patch) — final is applied last.
func TestPatchFinalOrder(t *testing.T) {
	base := writeTemp(t, "config.yaml", "mode: rule\n")
	p1 := writeTemp(t, "p1.json", `{"mode": "global"}`)
	p2 := writeTemp(t, "p2.json", `{"mode": "direct"}`)

	out, _, err := loadAndMergeConfig(base, p1, p2)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "mode: direct") {
		t.Errorf("patchFinal should win\n%s", out)
	}
}

// TestEmptyPatchPaths: empty patch paths are skipped (no yaml patch case).
func TestEmptyPatchPaths(t *testing.T) {
	base := writeTemp(t, "config.yaml", "mode: rule\n")
	out, _, err := loadAndMergeConfig(base, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "mode: rule") {
		t.Errorf("base config lost\n%s", out)
	}
}

// TestJSPatchRejected: .js patches must fail loudly, not silently pass.
func TestJSPatchRejected(t *testing.T) {
	base := writeTemp(t, "config.yaml", "mode: rule\n")
	js := writeTemp(t, "patch.js", "module.exports = {}")
	if _, _, err := loadAndMergeConfig(base, js, ""); err == nil {
		t.Fatal("expected error for js patch")
	}
}

// TestExtensionAppendSurvivesTopLevelReplace: when the patch both replaces a
// top-level list AND appends via extension, the append must land after the
// replacement (mergeExtension runs after deepMerge).
func TestExtensionAppendSurvivesTopLevelReplace(t *testing.T) {
	base := writeTemp(t, "config.yaml", `
rules:
  - DOMAIN-SUFFIX,old.com,Proxy
`)
	patch := writeTemp(t, "patch.json", `{
  "rules": ["DOMAIN-SUFFIX,new.com,Proxy"],
  "extension": {"append-rules": ["MATCH,Proxy"]}
}`)

	out, _, err := loadAndMergeConfig(base, patch, "")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out, "old.com") {
		t.Errorf("top-level rules should replace base\n%s", out)
	}
	if !strings.Contains(out, "new.com") {
		t.Errorf("replacement rule missing\n%s", out)
	}
	if !strings.Contains(out, "MATCH,Proxy") {
		t.Errorf("extension append must survive the top-level replace\n%s", out)
	}
}

// TestNormalizeNumbers: JSON numbers stay integral in YAML (ports not 7890.0).
func TestNormalizeNumbers(t *testing.T) {
	base := writeTemp(t, "config.yaml", "mixed-port: 7890\n")
	patch := writeTemp(t, "patch.json", `{"port": 7891}`)

	out, _, err := loadAndMergeConfig(base, patch, "")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out, "7891.0") {
		t.Errorf("port serialized as float\n%s", out)
	}
	if !strings.Contains(out, "port: 7891") {
		t.Errorf("port missing or wrong\n%s", out)
	}
}
