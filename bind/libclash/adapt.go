package libclash

import (
	"os"

	clash "github.com/ProjectClash/Clash/bind/clash"
)

// platformAdapter adapts the Swift PlatformInterface to the kernel's.
type platformAdapter struct {
	p       PlatformInterface
	logPath string
	errPath string
}

func (a *platformAdapter) WriteLog(message string) {
	if a.logPath != "" {
		appendFile(a.logPath, message+"\n")
	}
}

func (a *platformAdapter) OpenTun(options clash.TunOptions) (int32, error) {
	return a.p.OpenTun(&tunOptionsWrapper{k: options})
}

func (a *platformAdapter) TunFailed(reason string) {
	if a.errPath != "" {
		appendFile(a.errPath, "TunFailed: "+reason+"\n")
	}
}

func (a *platformAdapter) UsePlatformAutoDetectInterfaceControl() bool {
	return false
}

func (a *platformAdapter) AutoDetectInterfaceControl(fd int32) error {
	return nil
}

func (a *platformAdapter) StartDefaultInterfaceMonitor(listener clash.InterfaceUpdateListener) error {
	return nil
}

func (a *platformAdapter) CloseDefaultInterfaceMonitor(listener clash.InterfaceUpdateListener) error {
	return nil
}

func (a *platformAdapter) GetInterfaces() (clash.NetworkInterfaceIterator, error) {
	return &emptyNetworkInterfaceIterator{}, nil
}

func (a *platformAdapter) UnderNetworkExtension() bool {
	return true
}

type emptyNetworkInterfaceIterator struct{}

func (e *emptyNetworkInterfaceIterator) Len() int32                         { return 0 }
func (e *emptyNetworkInterfaceIterator) HasNext() bool                      { return false }
func (e *emptyNetworkInterfaceIterator) Next() *clash.NetworkInterface      { return nil }

// tunOptionsWrapper exposes the kernel TunOptions plus the HTTP proxy info
// carried in the patch's `extension.tun.http_proxy` block.
type tunOptionsWrapper struct {
	k clash.TunOptions
}

func (t *tunOptionsWrapper) GetAutoRoute() bool { return t.k.GetAutoRoute() }
func (t *tunOptionsWrapper) GetMTU() int32      { return t.k.GetMTU() }

func (t *tunOptionsWrapper) GetDNSServerAddress() (*StringBox, error) {
	box, err := t.k.GetDNSServerAddress()
	if err != nil {
		return nil, err
	}
	if box == nil {
		return &StringBox{}, nil
	}
	return &StringBox{Value: box.Value}, nil
}

func (t *tunOptionsWrapper) GetInet4Address() RoutePrefixIterator {
	return wrapRoutePrefixIterator(t.k.GetInet4Address())
}
func (t *tunOptionsWrapper) GetInet4RouteAddress() RoutePrefixIterator {
	return wrapRoutePrefixIterator(t.k.GetInet4RouteAddress())
}
func (t *tunOptionsWrapper) GetInet4RouteExcludeAddress() RoutePrefixIterator {
	return wrapRoutePrefixIterator(t.k.GetInet4RouteExcludeAddress())
}
func (t *tunOptionsWrapper) GetInet6Address() RoutePrefixIterator {
	return wrapRoutePrefixIterator(t.k.GetInet6Address())
}
func (t *tunOptionsWrapper) GetInet6RouteAddress() RoutePrefixIterator {
	return wrapRoutePrefixIterator(t.k.GetInet6RouteAddress())
}
func (t *tunOptionsWrapper) GetInet6RouteExcludeAddress() RoutePrefixIterator {
	return wrapRoutePrefixIterator(t.k.GetInet6RouteExcludeAddress())
}

func (t *tunOptionsWrapper) IsHTTPProxyEnabled() bool {
	mu.Lock()
	defer mu.Unlock()
	return httpProxy.Enable
}
func (t *tunOptionsWrapper) GetHTTPProxyServer() string {
	mu.Lock()
	defer mu.Unlock()
	if httpProxy.Server != "" {
		return httpProxy.Server
	}
	return "127.0.0.1"
}
func (t *tunOptionsWrapper) GetHTTPProxyServerPort() int32 {
	mu.Lock()
	defer mu.Unlock()
	return httpProxy.Port
}
func (t *tunOptionsWrapper) GetHTTPProxyBypassDomain() StringIterator {
	mu.Lock()
	defer mu.Unlock()
	return newStringIterator(httpProxy.Bypass)
}
func (t *tunOptionsWrapper) GetHTTPProxyMatchDomain() StringIterator {
	mu.Lock()
	defer mu.Unlock()
	return newStringIterator(httpProxy.Match)
}

// routePrefixAdapter wraps the kernel RoutePrefix.
type routePrefixAdapter struct {
	p *clash.RoutePrefix
}

func (r *routePrefixAdapter) Address() string { return r.p.Address() }
func (r *routePrefixAdapter) Mask() string    { return r.p.Mask() }
func (r *routePrefixAdapter) Prefix() int32   { return r.p.Prefix() }

type routePrefixIteratorAdapter struct {
	it clash.RoutePrefixIterator
}

func (i *routePrefixIteratorAdapter) HasNext() bool { return i.it.HasNext() }
func (i *routePrefixIteratorAdapter) Next() RoutePrefix {
	p := i.it.Next()
	if p == nil {
		return nil
	}
	return &routePrefixAdapter{p: p}
}

func wrapRoutePrefixIterator(it clash.RoutePrefixIterator) RoutePrefixIterator {
	if it == nil {
		return &emptyRoutePrefixIterator{}
	}
	return &routePrefixIteratorAdapter{it: it}
}

type emptyRoutePrefixIterator struct{}

func (e *emptyRoutePrefixIterator) HasNext() bool   { return false }
func (e *emptyRoutePrefixIterator) Next() RoutePrefix { return nil }

type stringSliceIterator struct {
	values []string
	index  int
}

func newStringIterator(values []string) StringIterator {
	return &stringSliceIterator{values: values}
}

func (s *stringSliceIterator) HasNext() bool { return s.index < len(s.values) }
func (s *stringSliceIterator) Next() string {
	if s.index >= len(s.values) {
		return ""
	}
	v := s.values[s.index]
	s.index++
	return v
}

func appendFile(path, content string) {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	_, _ = f.WriteString(content)
}
