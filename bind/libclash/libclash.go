// Package libclash is a gomobile-bindable facade that exposes the public
// ProjectClash kernel (github.com/ProjectClash/Clash/bind/clash) through the
// exact API surface the clashmi Swift glue (bind/apple/LibVpnCore) expects.
//
// Binding this package produces Libclash.xcframework / Libclash.h with the
// LibclashSetup / LibclashStart / LibclashStop / LibclashGetConnections /
// LibclashGetTraffic symbols, so the Swift side compiles unchanged.
//
// NOTE: this package is copied into the kernel checkout at
// `bind/clash/libclash/` before binding (see scripts/build_libclash_core.sh),
// because the kernel's bind module relies on repo-relative replace directives.
package libclash

import (
	"errors"
	"path/filepath"
	"sync"

	clash "github.com/ProjectClash/Clash/bind/clash"
)

// SetupOptions mirrors the closed-core setup call.
type SetupOptions struct {
	HomeDir   string
	LogFile   string
	ErrorFile string
}

// StartOptions mirrors the closed-core start call.
type StartOptions struct {
	ConfigFile         string
	ConfigFilePatch    string
	ConfigFilePatchFinal string
}

// StringBox is a gomobile-friendly string wrapper (accessed as .value in Swift).
type StringBox struct {
	Value string
}

// RoutePrefix is one address/prefix entry returned by TunOptions iterators.
type RoutePrefix interface {
	Address() string
	Mask() string
	Prefix() int32
}

// RoutePrefixIterator iterates RoutePrefix values.
type RoutePrefixIterator interface {
	HasNext() bool
	Next() RoutePrefix
}

// StringIterator iterates strings.
type StringIterator interface {
	HasNext() bool
	Next() string
}

// TunOptions is consumed by the Swift platform layer when opening the TUN.
type TunOptions interface {
	GetAutoRoute() bool
	GetMTU() int32
	GetDNSServerAddress() (*StringBox, error)
	GetInet4Address() RoutePrefixIterator
	GetInet4RouteAddress() RoutePrefixIterator
	GetInet4RouteExcludeAddress() RoutePrefixIterator
	GetInet6Address() RoutePrefixIterator
	GetInet6RouteAddress() RoutePrefixIterator
	GetInet6RouteExcludeAddress() RoutePrefixIterator
	IsHTTPProxyEnabled() bool
	GetHTTPProxyServer() string
	GetHTTPProxyServerPort() int32
	GetHTTPProxyBypassDomain() StringIterator
	GetHTTPProxyMatchDomain() StringIterator
}

// PlatformInterface is implemented by the Swift side (ExtensionPlatformInterface).
// Keep this set EXACTLY in sync with the Swift implementations.
type PlatformInterface interface {
	OpenTun(options TunOptions) (int32, error)
	FindConnectionOwner(uid int32, sourceAddress string, sourcePort int32, destinationAddress string, destinationPort int32) (int32, error)
	PackageNameByUid(uid int32) (string, error)
	ProtectFd(fd int32)
}

var (
	mu            sync.Mutex
	currentService *clash.BoxService
	logPath       string
	errPath       string
	httpProxy     = httpProxyInfo{Server: "127.0.0.1"}
)

// Setup prepares the core runtime (home/log paths). Safe to call repeatedly.
func Setup(options *SetupOptions) error {
	if options == nil {
		return errors.New("nil setup options")
	}
	mu.Lock()
	logPath, errPath = options.LogFile, options.ErrorFile
	mu.Unlock()

	so := &clash.SetupOptions{
		BasePath:            options.HomeDir,
		WorkingPath:         filepath.Join(options.HomeDir, "working"),
		TempPath:            filepath.Join(options.HomeDir, "temp"),
		StartupPhaseLogPath: options.LogFile,
		LogMaxLines:         1000,
	}
	if err := clash.Setup(so); err != nil {
		writeErrorFile("LibclashSetup failed: " + err.Error())
		return err
	}
	return nil
}

// Start loads the config file, applies the JSON/YAML patches and starts core.
func Start(options *StartOptions, platformInterface PlatformInterface) error {
	if options == nil {
		return errors.New("nil start options")
	}
	if platformInterface == nil {
		return errors.New("nil platform interface")
	}

	mu.Lock()
	if currentService != nil {
		_ = currentService.Close()
		currentService = nil
	}
	mu.Unlock()

	merged, hp, err := loadAndMergeConfig(options.ConfigFile, options.ConfigFilePatch, options.ConfigFilePatchFinal)
	if err != nil {
		writeErrorFile("LibclashStart: " + err.Error())
		return err
	}

	mu.Lock()
	httpProxy = *hp
	log, errp := logPath, errPath
	mu.Unlock()

	adapter := &platformAdapter{p: platformInterface, logPath: log, errPath: errp}
	svc, err := clash.NewService(adapter)
	if err != nil {
		writeErrorFile("LibclashStart: new service: " + err.Error())
		return err
	}
	if err := svc.Start(merged); err != nil {
		_ = svc.Close()
		writeErrorFile("LibclashStart: start: " + err.Error())
		return err
	}

	mu.Lock()
	currentService = svc
	mu.Unlock()
	return nil
}

// Stop closes the running core service.
func Stop() error {
	mu.Lock()
	svc := currentService
	currentService = nil
	mu.Unlock()
	if svc == nil {
		return nil
	}
	return svc.Close()
}

// GetConnections returns the connections snapshot as JSON.
func GetConnections(includeClosed bool) string {
	return clash.ConnectionsJSON()
}

// GetTraffic returns current traffic rates as JSON.
func GetTraffic() string {
	return clash.TrafficJSON()
}

func writeErrorFile(message string) {
	mu.Lock()
	path := errPath
	mu.Unlock()
	if path != "" {
		appendFile(path, message+"\n")
	}
}
