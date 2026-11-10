// Command roothelper runs the Clash Mi core as a standalone root process on
// TrollStore-installed iOS devices, providing a user-space "FakeVPN" tunnel
// without any NetworkExtension involvement (ldid fake-signed .appex / main-app
// providers are both rejected by nesessionmanager with "需要更新").
//
// Lifecycle (driven by the main app via TrollStore spawnRoot):
//
//	start:  roothelper <configFile> <configFilePatch> <configFilePatchFinal> <homeDir> <logFile> <errFile> <pidFile> <ifaceNameFile>
//	        1. writes pidfile
//	        2. LibclashSetup + LibclashStart with an in-process PlatformInterface
//	        3. PlatformInterface.OpenTun opens a utun device, configures its
//	           addresses and installs the routes requested by the kernel
//	        4. blocks until SIGTERM/SIGINT, then removes routes and exits
//	stop:   roothelper stop <pidFile>   (sends SIGTERM to the recorded pid)
//
// The binary is declared in the app Info.plist TSRootBinaries array and is
// spawned via TrollStore's spawnRoot (com.apple.private.persona-mgmt), so it
// runs as root and may modify the system routing table.
package main

import (
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"unsafe"

	libclash "github.com/ProjectClash/Clash/bind/clash/libclash"
	"golang.org/x/net/route"
	"golang.org/x/sys/unix"
)

const (
	utunControlName  = "com.apple.net.utun_control"
	sysProtoControl  = 0x2  // SYSPROTO_CONTROL
	utunOptIfName    = 0x2  // UTUN_OPT_IFNAME
	sioCAIFADDRIn6   = 0x8080691A // SIOCAIFADDR_IN6 (darwin)
)

// routeEntry remembers one installed route so we can delete it on shutdown.
type routeEntry struct {
	dst  route.Addr
	ifID string // gateway interface name (rtax_gateway link address)
}

var installedRoutes []routeEntry
var tunIfaceName string
var tunIfaceIndex int

func main() {
	args := os.Args[1:]
	if len(args) > 0 && args[0] == "stop" {
		if len(args) < 2 {
			die("usage: roothelper stop <pidFile>")
		}
		stopMode(args[1])
		return
	}
	if len(args) < 8 {
		die("usage: roothelper <configFile> <configFilePatch> <configFilePatchFinal> <homeDir> <logFile> <errFile> <pidFile> <ifaceNameFile>")
	}
	configFile, configPatch, configPatchFinal := args[0], args[1], args[2]
	homeDir, logFile, errFile := args[3], args[4], args[5]
	pidFile, ifaceNameFile := args[6], args[7]

	if os.Geteuid() != 0 {
		die("roothelper must run as root (spawnRoot/persona-mgmt)")
	}
	writeFile(pidFile, []byte(strconv.Itoa(os.Getpid())))

	sig := make(chan os.Signal, 2)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)

	if err := libclash.Setup(&libclash.SetupOptions{
		HomeDir: homeDir, LogFile: logFile, ErrorFile: errFile,
	}); err != nil {
		die("setup: " + err.Error())
	}

	if err := libclash.Start(&libclash.StartOptions{
		ConfigFile:           configFile,
		ConfigFilePatch:      configPatch,
		ConfigFilePatchFinal: configPatchFinal,
	}, &rootPlatform{}); err != nil {
		die("start: " + err.Error())
	}

	writeFile(ifaceNameFile, []byte(tunIfaceName))
	logLine(errFile, "roothelper: tunnel up on "+tunIfaceName)

	<-sig

	logLine(errFile, "roothelper: shutting down")
	_ = libclash.Stop()
	removeRoutes()
	_ = os.Remove(pidFile)
	_ = os.Remove(ifaceNameFile)
	os.Exit(0)
}

func stopMode(pidFile string) {
	pidBytes, err := os.ReadFile(pidFile)
	if err != nil {
		// Already gone.
		return
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(pidBytes)))
	if err != nil || pid <= 0 {
		return
	}
	_ = syscall.Kill(pid, syscall.SIGTERM)
}

func die(msg string) {
	fmt.Fprintln(os.Stderr, "roothelper:", msg)
	os.Exit(1)
}

func writeFile(path string, data []byte) {
	if path == "" {
		return
	}
	_ = os.WriteFile(path, data, 0o644)
}

func logLine(errFile, msg string) {
	if errFile != "" {
		f, err := os.OpenFile(errFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		if err == nil {
			_, _ = f.WriteString(msg + "\n")
			_ = f.Close()
		}
	}
}

// ────────────────────────── PlatformInterface ──────────────────────────

type rootPlatform struct{}

func (p *rootPlatform) OpenTun(options libclash.TunOptions) (int32, error) {
	fd, name, err := openUtun(int(options.GetMTU()))
	if err != nil {
		return 0, err
	}
	tunIfaceName = name
	ifIdx, err := interfaceIndex(name)
	if err != nil {
		unix.Close(fd)
		return 0, err
	}
	tunIfaceIndex = ifIdx

	// IPv4/IPv6 addresses.
	if err := configureAddresses(fd, name, options); err != nil {
		unix.Close(fd)
		return 0, err
	}
	// Routes requested by the kernel (auto-route).
	if options.GetAutoRoute() {
		if err := addKernelRoutes(options, ifIdx); err != nil {
			unix.Close(fd)
			removeRoutes()
			return 0, err
		}
	}
	return int32(fd), nil
}

func (p *rootPlatform) FindConnectionOwner(uid int32, sourceAddress string, sourcePort int32, destinationAddress string, destinationPort int32) (int32, error) {
	return 0, errors.New("not implemented")
}

func (p *rootPlatform) PackageNameByUid(uid int32) (string, error) {
	return "", nil
}

func (p *rootPlatform) ProtectFd(fd int32) {}

// ─────────────────────────────── utun ───────────────────────────────

func openUtun(mtu int) (int, string, error) {
	if mtu <= 0 {
		mtu = 4064
	}
	fd, err := unix.Socket(unix.AF_SYSTEM, unix.SOCK_DGRAM, sysProtoControl)
	if err != nil {
		return 0, "", os.NewSyscallError("socket(AF_SYSTEM)", err)
	}
	ctlInfo := &unix.CtlInfo{}
	copy(ctlInfo.Name[:], utunControlName)
	if err := unix.IoctlCtlInfo(fd, ctlInfo); err != nil {
		unix.Close(fd)
		return 0, "", os.NewSyscallError("IoctlCtlInfo", err)
	}
	// Unit 0 asks the kernel to allocate a free utun index.
	if err := unix.Connect(fd, &unix.SockaddrCtl{ID: ctlInfo.Id, Unit: 0}); err != nil {
		unix.Close(fd)
		return 0, "", os.NewSyscallError("connect(utun)", err)
	}
	nameBytes, err := unix.GetsockoptString(fd, sysProtoControl, utunOptIfName)
	if err != nil {
		unix.Close(fd)
		return 0, "", os.NewSyscallError("getsockopt(UTUN_OPT_IFNAME)", err)
	}
	name := strings.TrimRight(nameBytes, "\x00")
	if !strings.HasPrefix(name, "utun") {
		unix.Close(fd)
		return 0, "", fmt.Errorf("unexpected utun name %q", name)
	}
	if err := setInterfaceMTU(name, mtu); err != nil {
		unix.Close(fd)
		return 0, "", err
	}
	return fd, name, nil
}

func interfaceIndex(name string) (int, error) {
	iface, err := net.InterfaceByName(name)
	if err != nil {
		return 0, err
	}
	return iface.Index, nil
}

func setInterfaceMTU(name string, mtu int) error {
	return withInetSocket(func(s int) error {
		var ifr unix.IfreqMTU
		copy(ifr.Name[:], name)
		ifr.MTU = int32(mtu)
		return unix.IoctlSetIfreqMTU(s, &ifr)
	})
}

func withInetSocket(fn func(fd int) error) error {
	s, err := unix.Socket(unix.AF_INET, unix.SOCK_DGRAM, 0)
	if err != nil {
		return err
	}
	defer unix.Close(s)
	return fn(s)
}

// ──────────────────────────── addresses ────────────────────────────────

func configureAddresses(fd int, name string, options libclash.TunOptions) error {
	if err := addInet4Aliases(name, options); err != nil {
		return err
	}
	return addInet6Aliases(name, options)
}

type ifAliasReq struct {
	Name    [unix.IFNAMSIZ]byte
	Addr    unix.RawSockaddrInet4
	Dstaddr unix.RawSockaddrInet4
	Mask    unix.RawSockaddrInet4
}

func inet4Alias(name string, prefix netip.Prefix) ifAliasReq {
	ip := prefix.Addr().As4()
	mask := net.CIDRMask(prefix.Bits(), 32)
	var maskArr [4]byte
	copy(maskArr[:], mask)
	var req ifAliasReq
	copy(req.Name[:], name)
	req.Addr = unix.RawSockaddrInet4{Len: unix.SizeofSockaddrInet4, Family: unix.AF_INET, Addr: ip}
	req.Dstaddr = unix.RawSockaddrInet4{Len: unix.SizeofSockaddrInet4, Family: unix.AF_INET, Addr: ip}
	req.Mask = unix.RawSockaddrInet4{Len: unix.SizeofSockaddrInet4, Family: unix.AF_INET, Addr: maskArr}
	return req
}

func addInet4Aliases(name string, options libclash.TunOptions) error {
	it := options.GetInet4Address()
	for it != nil && it.HasNext() {
		p := it.Next()
		if p == nil {
			continue
		}
		ip, err := netip.ParsePrefix(p.Address() + "/" + strconv.Itoa(int(p.Prefix())))
		if err != nil {
			continue
		}
		req := inet4Alias(name, ip)
		r := req
		err = withInetSocket(func(s int) error {
			_, _, errno := unix.Syscall(syscall.SYS_IOCTL, uintptr(s), uintptr(unix.SIOCAIFADDR), uintptr(unsafe.Pointer(&r)))
			if errno != 0 {
				return os.NewSyscallError("SIOCAIFADDR", errno)
			}
			return nil
		})
		if err != nil {
			return err
		}
	}
	return nil
}

func addInet6Aliases(name string, options libclash.TunOptions) error {
	it := options.GetInet6Address()
	for it != nil && it.HasNext() {
		p := it.Next()
		if p == nil {
			continue
		}
		// inet6 alias via SIOCAIFADDR_IN6 (struct in6_ifreq).
		var req inet6AliasReq
		copy(req.Name[:], name)
		addr, err := netip.ParsePrefix(p.Address() + "/" + strconv.Itoa(int(p.Prefix())))
		if err != nil {
			continue
		}
		as16 := addr.Addr().As16()
		copy(req.Addr[:], as16[:])
		req.PrefixLen = int32(addr.Bits())
		r := req
		err = withInet6Socket(func(s int) error {
			_, _, errno := unix.Syscall(syscall.SYS_IOCTL, uintptr(s), uintptr(sioCAIFADDRIn6), uintptr(unsafe.Pointer(&r)))
			if errno != 0 {
				return os.NewSyscallError("SIOCAIFADDR_IN6", errno)
			}
			return nil
		})
		if err != nil {
			return err
		}
	}
	return nil
}

type inet6AliasReq struct {
	Name      [unix.IFNAMSIZ]byte
	Addr      [16]byte
	PrefixLen int32
	_         [128]byte // pad to a safe size for in6_ifreq
}

func withInet6Socket(fn func(fd int) error) error {
	s, err := unix.Socket(unix.AF_INET6, unix.SOCK_DGRAM, 0)
	if err != nil {
		return err
	}
	defer unix.Close(s)
	return fn(s)
}

// ────────────────────────────── routes ────────────────────────────────

func addKernelRoutes(options libclash.TunOptions, ifIdx int) error {
	if err := addRouteFamily4(options, ifIdx); err != nil {
		return err
	}
	return addRouteFamily6(options, ifIdx)
}

func collect4(it libclash.RoutePrefixIterator) []netip.Prefix {
	var out []netip.Prefix
	for it != nil && it.HasNext() {
		p := it.Next()
		if p == nil {
			continue
		}
		pfx, err := netip.ParsePrefix(p.Address() + "/" + strconv.Itoa(int(p.Prefix())))
		if err == nil {
			out = append(out, pfx)
		}
	}
	return out
}

func addRouteFamily4(options libclash.TunOptions, ifIdx int) error {
	var dsts []netip.Prefix
	if it := options.GetInet4RouteAddress(); it != nil && it.HasNext() {
		dsts = collect4(it)
	} else {
		dsts = []netip.Prefix{netip.MustParsePrefix("0.0.0.0/0")}
	}
	excludes := map[string]bool{}
	for _, p := range collect4(options.GetInet4RouteExcludeAddress()) {
		excludes[p.String()] = true
	}
	for _, dst := range dsts {
		if excludes[dst.String()] {
			continue
		}
		if err := addRoute4(dst, ifIdx); err != nil {
			return err
		}
	}
	return nil
}

func addRouteFamily6(options libclash.TunOptions, ifIdx int) error {
	var dsts []netip.Prefix
	if it := options.GetInet6RouteAddress(); it != nil && it.HasNext() {
		dsts = collect6(it)
	} else {
		dsts = []netip.Prefix{netip.MustParsePrefix("::/0")}
	}
	excludes := map[string]bool{}
	for _, p := range collect6(options.GetInet6RouteExcludeAddress()) {
		excludes[p.String()] = true
	}
	for _, dst := range dsts {
		if excludes[dst.String()] {
			continue
		}
		if err := addRoute6(dst, ifIdx); err != nil {
			return err
		}
	}
	return nil
}

func collect6(it libclash.RoutePrefixIterator) []netip.Prefix {
	var out []netip.Prefix
	for it != nil && it.HasNext() {
		p := it.Next()
		if p == nil {
			continue
		}
		pfx, err := netip.ParsePrefix(p.Address() + "/" + strconv.Itoa(int(p.Prefix())))
		if err == nil {
			out = append(out, pfx)
		}
	}
	return out
}

func addRoute4(dst netip.Prefix, ifIdx int) error {
	addr := &route.Inet4Addr{IP: dst.Addr().As4()}
	return changeRoute(syscall.RTM_ADD, addr, ifIdx)
}

func addRoute6(dst netip.Prefix, ifIdx int) error {
	addr := &route.Inet6Addr{IP: dst.Addr().As16()}
	return changeRoute(syscall.RTM_ADD, addr, ifIdx)
}

func removeRoutes() {
	for i := len(installedRoutes) - 1; i >= 0; i-- {
		r := installedRoutes[i]
		_ = changeRouteNamed(syscall.RTM_DELETE, r.dst, r.ifID)
	}
	installedRoutes = nil
}

func changeRoute(typ int, dst route.Addr, ifIdx int) error {
	iface, err := net.InterfaceByIndex(ifIdx)
	if err != nil {
		return err
	}
	return changeRouteNamed(typ, dst, iface.Name)
}

// changeRouteNamed adds/deletes a route whose gateway is the named interface
// (scope-link gateway, i.e. "route ... -interface utunX").
func changeRouteNamed(typ int, dst route.Addr, ifName string) error {
	m := &route.RouteMessage{
		Type:    typ,
		Flags:   syscall.RTF_UP | syscall.RTF_STATIC,
		Seq:     1,
		Version: syscall.RTM_VERSION,
		Addrs: []route.Addr{
			dst,
			&route.LinkAddr{Name: ifName}, // gateway = interface (scope link)
		},
	}
	data, err := m.Marshal()
	if err != nil {
		return err
	}
	s, err := unix.Socket(unix.AF_ROUTE, unix.SOCK_RAW, 0)
	if err != nil {
		return err
	}
	defer unix.Close(s)
	for {
		if _, err := unix.Write(s, data); err == nil {
			break
		} else if err == syscall.EINTR {
			continue
		} else {
			// EEXIST on add is fine (idempotent reconnect).
			if typ == syscall.RTM_ADD && err == syscall.EEXIST {
				break
			}
			return os.NewSyscallError("route", err)
		}
	}
	if typ == syscall.RTM_ADD {
		installedRoutes = append(installedRoutes, routeEntry{dst: dst, ifID: ifName})
	}
	return nil
}
