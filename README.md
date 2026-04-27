# home-server
k8s home server with cloudflare tunnels

## Flow of a Request
User visits app1.yourdomain.com.

Cloudflare DNS has a CNAME record pointing to your-tunnel-id.cfargotunnel.com.

Cloudflare edge looks up the tunnel (by that CNAME target) and forwards the request through a persistent, encrypted connection to the cloudflared pod inside your cluster.

The cloudflared pod reads config.yml (from the ConfigMap) and matches the incoming hostname against the ingress rules.

It finds hostname: app1.yourdomain.com → http://app1-svc.default.svc.cluster.local:80.

It proxies the request to that internal service (using Kubernetes DNS).

The service responds, and the tunnel sends the response back to the user.


## Install Prereqs
- git: https://git-scm.com/install/linux
- k3s: https://docs.k3s.io/quick-start

## Clone Repository
git clone "https://github.com/jtan-gh/home-server.git"

## Install Cloudflared CL (First Time)
Only follow Steps 1 and 2
https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/create-local-tunnel/

You should now have...
A tunnel credentials file {UUID}.json in the [default cloudflared directory](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/local-tunnel-terms/#default-cloudflared-directory).

check
```
ls ~/.cloudflared
```

## Alternative: Reissue Cloudflared Tunnel Credentials
https://community.cloudflare.com/t/how-to-recover-or-reissue-credentials-json-for-existing-tunnel/802258

## Run Script to deploy cloudflared resources
```
./setup
```
double check to ensure ./cloudflared/configmap.yaml contains the UUID. setup script should've overwritten it with your tunnel UUID
