// pluck-tunnel: the private network for Pluck's Edit Anywhere, built on Tailscale's tsnet. It runs
// in its own process, joins the team's private network (tailnet) as its own node, and only
// carries Edit Anywhere: nothing else on the Mac uses it, and it's no system VPN.
//
//	office: listens on the private network on Edit Anywhere's port and hands each connection to
//	        Pluck on this Mac (127.0.0.1).
//	home:   opens a local port (127.0.0.1) whose connections go to the office Mac over the
//	        private network.
//
// Its settings come as one JSON line on stdin (so a join key never shows in the process list);
// it reports as JSON lines on stdout and quits when stdin closes (Pluck quit).
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"sync"
	"time"

	"tailscale.com/ipn"
	"tailscale.com/tsnet"
)

type config struct {
	Mode     string `json:"mode"`     // "office" or "home"
	Dir      string `json:"dir"`      // where the node keeps its identity
	Hostname string `json:"hostname"` // its name on the private network
	AuthKey  string `json:"authKey"`  // only needed to join the first time
	Port     int    `json:"port"`     // Edit Anywhere's port
	Office   string `json:"office"`   // home: the office node's address on the private network
}

var outMu sync.Mutex

func report(v map[string]any) {
	outMu.Lock()
	defer outMu.Unlock()
	b, _ := json.Marshal(v)
	fmt.Println(string(b))
}

func main() {
	in := bufio.NewReader(os.Stdin)
	line, err := in.ReadString('\n')
	if err != nil {
		report(map[string]any{"error": "no settings"})
		os.Exit(1)
	}
	var cfg config
	if err := json.Unmarshal([]byte(line), &cfg); err != nil || cfg.Dir == "" || cfg.Port <= 0 {
		report(map[string]any{"error": "bad settings"})
		os.Exit(1)
	}
	// Quit with Pluck.
	go func() {
		io.Copy(io.Discard, in)
		os.Exit(0)
	}()

	srv := &tsnet.Server{
		Dir:       cfg.Dir,
		Hostname:  cfg.Hostname,
		AuthKey:   cfg.AuthKey,
		Ephemeral: false,
		Logf:      func(string, ...any) {},
		UserLogf:  func(string, ...any) {},
	}
	if err := srv.Start(); err != nil {
		report(map[string]any{"error": err.Error()})
		os.Exit(1)
	}
	if !waitRunning(srv, cfg.AuthKey != "") {
		os.Exit(2)
	}
	switch cfg.Mode {
	case "office":
		office(srv, cfg)
	case "home":
		home(srv, cfg)
	default:
		report(map[string]any{"error": "unknown mode"})
		os.Exit(1)
	}
}

// waitRunning waits until the node is on the private network. Without a key it reports
// "needsKey" when it isn't joined yet (Pluck then gets a key and starts it again).
func waitRunning(srv *tsnet.Server, haveKey bool) bool {
	lc, err := srv.LocalClient()
	if err != nil {
		report(map[string]any{"error": err.Error()})
		return false
	}
	deadline := time.Now().Add(90 * time.Second)
	for time.Now().Before(deadline) {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		st, err := lc.Status(ctx)
		cancel()
		if err == nil {
			switch st.BackendState {
			case ipn.Running.String():
				ips := []string{}
				for _, ip := range st.TailscaleIPs {
					ips = append(ips, ip.String())
				}
				name := ""
				if st.Self != nil {
					name = strings.TrimSuffix(st.Self.DNSName, ".")
				}
				report(map[string]any{"state": "running", "ips": ips, "name": name})
				return true
			case ipn.NeedsLogin.String():
				if !haveKey {
					report(map[string]any{"state": "needsKey"})
					return false
				}
			case ipn.NeedsMachineAuth.String():
				report(map[string]any{"state": "needsApproval"})
			}
		}
		time.Sleep(500 * time.Millisecond)
	}
	report(map[string]any{"error": "The private network didn’t answer in time."})
	return false
}

func office(srv *tsnet.Server, cfg config) {
	ln, err := srv.Listen("tcp", fmt.Sprintf(":%d", cfg.Port))
	if err != nil {
		report(map[string]any{"error": err.Error()})
		os.Exit(1)
	}
	report(map[string]any{"state": "listening"})
	local := fmt.Sprintf("127.0.0.1:%d", cfg.Port)
	for {
		c, err := ln.Accept()
		if err != nil {
			report(map[string]any{"error": err.Error()})
			os.Exit(1)
		}
		go func() {
			p, err := net.DialTimeout("tcp", local, 5*time.Second)
			if err != nil {
				c.Close()
				return
			}
			pipe(c, p)
		}()
	}
}

func home(srv *tsnet.Server, cfg config) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		report(map[string]any{"error": err.Error()})
		os.Exit(1)
	}
	report(map[string]any{"state": "listening", "listen": ln.Addr().String()})
	target := net.JoinHostPort(cfg.Office, fmt.Sprint(cfg.Port))
	for {
		c, err := ln.Accept()
		if err != nil {
			report(map[string]any{"error": err.Error()})
			os.Exit(1)
		}
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			p, err := srv.Dial(ctx, "tcp", target)
			if err != nil {
				c.Close()
				return
			}
			pipe(c, p)
		}()
	}
}

// pipe copies both ways until either side closes.
func pipe(a, b net.Conn) {
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { io.Copy(a, b); a.Close(); b.Close(); wg.Done() }()
	go func() { io.Copy(b, a); a.Close(); b.Close(); wg.Done() }()
	wg.Wait()
}
