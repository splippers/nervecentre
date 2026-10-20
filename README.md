# NerveCentre

A unified LAN entry point and control plane for Splippers applications.

Type: Infrastructure / Meta-System  
Intent: Pillar + Enabler  
Audience: Self, operators, trusted collaborators

==================================================

OVERVIEW

NerveCentre is the connective tissue of the Splippers ecosystem.

It provides a single, human-friendly LAN entry point that ties together multiple independent services using nginx reverse proxying, redirects, and optional load balancing.

NerveCentre is intentionally simple in concept and explicit in behaviour. It does not attempt to abstract away the network — it documents it.

==================================================

WHAT NERVECENTRE IS

NerveCentre is:

- A unified landing page for Splippers services
- An nginx-based reverse proxy and redirect hub
- A deployment playbook for a small, resilient LAN stack
- A coordination point for multiple machines and services
- A place where infrastructure decisions are recorded once

NerveCentre is not:

- A public SaaS
- A cloud platform
- Kubernetes
- A service mesh framework
- A single-host assumption

==================================================

DESIGN PHILOSOPHY

CURRENT DEPLOYMENT: EDDIE (192.168.1.1)  
Internal: http://192.168.1.1/nc/  
External: https://nc.splippers.com/nc/ (Cloudflare tunnel to Eddie port 80, TLS at the edge)  

All services are proxied under a /nc/ path prefix. This is the only supported deployment topology.

NO CANONICAL HOST  
There is no “correct” machine. NerveCentre can live on Eddie, a dedicated load balancer, or behind a floating VIP.

VISIBILITY OVER MAGIC  
Services are proxied or redirected deliberately. When path-prefix proxying is brittle, HTTP redirects are used instead.

LAN-FIRST TRUST  
The threat model assumes a trusted LAN. Authentication and encryption are added where they add clarity, not friction.

SURVIVABILITY  
If one node disappears, the system continues to function with minimal reconfiguration.

==================================================

WHAT IT UNIFIES

NerveCentre ties together independent services such as:

- Brickwise (storage / Gluster coordination)
- Splippers Archive
- Symposium of Infinite Contention (SIC)
- Monyatron
- Jonotron
- Deanotron
- Charkive (SAN fluff scanner)
- Project prioritiser dashboard (projectscan)

Each service remains independently runnable. NerveCentre does not own them — it routes to them.

==================================================

ROUTING MODEL

Port 80 serves a static landing page.

From there, services are exposed using one of three strategies:

1. Reverse proxy with path prefix  
   Used when the backend tolerates prefix stripping and URL rewriting.

2. HTTP redirect to host:port  
   Used when the backend assumes root paths or absolute URLs.

3. Load-balanced upstreams  
   Optional pooling across multiple machines using nginx upstreams.

This is a conscious trade-off between correctness and convenience.

==================================================

LOAD BALANCING AND REDUNDANCY

NerveCentre can load-balance selected services across multiple machines by declaring backend lists.

Typical use cases:
- Brickwise spread across Gluster nodes
- Archive and SIC pooled behind a VIP
- Stateless dashboards duplicated for resilience

Where pooling is not safe, redirect mode is preferred.

==================================================

INSTALLATION MODEL

NerveCentre provides:

- Clone-or-update helpers
- Full-stack “install everything” scripts
- systemd service installation for long-running components
- Optional nginx portal setup
- Dry-run modes for inspection

It assumes repositories live side-by-side under a common Projects directory and encodes that convention explicitly.

==================================================

HARDWARE CONTEXT

NerveCentre is designed to operate comfortably on small, real hardware.

Typical deployments include:
- Two or more modest x86_64 machines
- Local SSD for OS, NVMe for storage
- GlusterFS for shared storage
- 16GB RAM class machines
- Direct LAN connectivity

This is intentional. NerveCentre targets homelab reality, not hyperscale fantasy.

==================================================

RELATIONSHIP TO OTHER PROJECTS

NerveCentre is not interesting on its own.

Its value comes from:
- making other repos easier to operate
- reducing friction between experiments
- preserving institutional memory
- preventing one-off “snowflake installs”

It is the map that lets the territory grow.

==================================================

STATUS

Active and evolving.

NerveCentre will continue to change as new Splippers services appear and old ones retire.

Stability comes from explicitness, not from freezing behaviour.

==================================================

FINAL NOTE

If the other projects are organs, NerveCentre is the nervous system.

It does not think.
It connects.
