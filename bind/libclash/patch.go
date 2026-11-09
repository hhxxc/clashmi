package libclash

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"

	"go.yaml.in/yaml/v3"
)

// httpProxyInfo comes from the patch's `extension.tun.http_proxy` block and is
// surfaced through TunOptions for the NE system-proxy settings.
type httpProxyInfo struct {
	Enable bool
	Server string
	Port   int32
	Bypass []string
	Match  []string
}

// loadAndMergeConfig loads the base mihomo config and applies the two patch
// files (configFilePatch first, then configFilePatchFinal).
//
// Patch format: JSON (clashmi RawConfig schema = native mihomo config keys)
// or YAML with the same key layout. Special keys:
//   - `overwrite` / `overwrite-*` control keys (MapHelper semantics)
//   - `extension` block: append rules/proxy-groups, tun.http_proxy, ...
func loadAndMergeConfig(configFile, patchFile, patchFinalFile string) (string, *httpProxyInfo, error) {
	baseData, err := os.ReadFile(configFile)
	if err != nil {
		return "", nil, fmt.Errorf("read config: %w", err)
	}
	base, err := parseConfigMap(baseData)
	if err != nil {
		return "", nil, fmt.Errorf("parse config: %w", err)
	}

	hp := &httpProxyInfo{Server: "127.0.0.1"}
	for _, p := range []string{patchFile, patchFinalFile} {
		if p == "" {
			continue
		}
		if strings.HasSuffix(strings.ToLower(p), ".js") {
			return "", nil, errors.New("js config patches are not supported by this build: " + p)
		}
		patchData, err := os.ReadFile(p)
		if err != nil {
			return "", nil, fmt.Errorf("read patch %s: %w", p, err)
		}
		patch, err := parseConfigMap(patchData)
		if err != nil {
			return "", nil, fmt.Errorf("parse patch %s: %w", p, err)
		}
		filterControlKeys(patch)
		mergeExtension(base, patch, hp)
		deepMerge(base, patch)
	}

	if hp.Port == 0 {
		hp.Port = int32FromAny(base["mixed-port"])
		if hp.Port == 0 {
			hp.Port = int32FromAny(base["port"])
		}
	}

	out, err := yaml.Marshal(base)
	if err != nil {
		return "", nil, fmt.Errorf("marshal merged config: %w", err)
	}
	return string(out), hp, nil
}

func parseConfigMap(data []byte) (map[string]any, error) {
	m := map[string]any{}
	if json.Valid(data) {
		if err := json.Unmarshal(data, &m); err != nil {
			return nil, err
		}
	} else {
		if err := yaml.Unmarshal(data, &m); err != nil {
			return nil, err
		}
	}
	normalizeNumbers(m)
	return m, nil
}

// normalizeNumbers converts JSON float64 values that are integral into int so
// the merged YAML keeps port numbers etc. as integers.
func normalizeNumbers(m map[string]any) {
	for k, v := range m {
		switch t := v.(type) {
		case float64:
			if t == float64(int64(t)) {
				m[k] = int64(t)
			}
		case map[string]any:
			normalizeNumbers(t)
		case []any:
			for _, item := range t {
				if sub, ok := item.(map[string]any); ok {
					normalizeNumbers(sub)
				}
			}
		}
	}
}

// filterControlKeys mirrors MapHelper.removeNullOrEmpty(map, true, true) from
// the Dart side: strips `overwrite` / `overwrite-*` control keys and drops the
// entries they veto.
func filterControlKeys(m map[string]any) {
	for k, v := range m {
		if v == nil {
			delete(m, k)
			continue
		}
		if k == "overwrite" {
			delete(m, k)
			continue
		}
		if strings.HasPrefix(k, "overwrite-") {
			delete(m, k)
			if v != true {
				delete(m, strings.TrimPrefix(k, "overwrite-"))
			}
			continue
		}
		if sub, ok := v.(map[string]any); ok {
			if ow, isBool := sub["overwrite"].(bool); isBool && !ow {
				m[k] = map[string]any{}
			} else {
				filterControlKeys(sub)
			}
			if empty, _ := m[k].(map[string]any); len(empty) == 0 {
				delete(m, k)
			}
		}
	}
}

// mergeExtension pulls the clashmi `extension` block out of the patch and
// applies its append semantics on top of the base config.
func mergeExtension(base, patch map[string]any, hp *httpProxyInfo) {
	ext, ok := patch["extension"].(map[string]any)
	if !ok {
		return
	}
	delete(patch, "extension")

	appendList(base, "rules", ext["rules"])
	appendList(base, "rules", ext["append-rules"])
	appendList(base, "proxy-groups", ext["proxy-groups"])
	appendList(base, "proxy-groups", ext["append-proxy-groups"])
	mergeMapInto(base, "rule-providers", ext["rule-providers"])
	mergeMapInto(base, "rule-providers", ext["append-rule-providers"])

	if tun, ok := ext["tun"].(map[string]any); ok {
		if p, ok := tun["http_proxy"].(map[string]any); ok {
			hp.Enable = toBool(p["enable"])
			if s, ok := p["server"].(string); ok && s != "" {
				hp.Server = s
			}
			hp.Port = int32FromAny(p["server_port"])
			hp.Bypass = toStringSlice(p["bypass_domain"])
			hp.Match = toStringSlice(p["match_domain"])
		}
	}
}

func appendList(base map[string]any, key string, extra any) {
	items := toStringSlice(extra)
	if len(items) == 0 {
		return
	}
	base[key] = append(toStringSlice(base[key]), items...)
}

func mergeMapInto(base map[string]any, key string, extra any) {
	extraMap, ok := extra.(map[string]any)
	if !ok || len(extraMap) == 0 {
		return
	}
	dst, _ := base[key].(map[string]any)
	if dst == nil {
		dst = map[string]any{}
		base[key] = dst
	}
	for k, v := range extraMap {
		dst[k] = v
	}
}

// deepMerge merges src into dst: nested maps merge recursively, everything else
// is replaced by src.
func deepMerge(dst, src map[string]any) {
	for k, v := range src {
		if sub, ok := v.(map[string]any); ok {
			if dstSub, ok := dst[k].(map[string]any); ok {
				deepMerge(dstSub, sub)
				continue
			}
		}
		dst[k] = v
	}
}

func toBool(v any) bool {
	b, _ := v.(bool)
	return b
}

func int32FromAny(v any) int32 {
	switch t := v.(type) {
	case int64:
		return int32(t)
	case int32:
		return t
	case int:
		return int32(t)
	case float64:
		return int32(t)
	case json.Number:
		i, _ := t.Int64()
		return int32(i)
	}
	return 0
}

func toStringSlice(v any) []string {
	switch t := v.(type) {
	case []string:
		return t
	case []any:
		out := make([]string, 0, len(t))
		for _, item := range t {
			if s, ok := item.(string); ok {
				out = append(out, s)
			}
		}
		return out
	}
	return nil
}
