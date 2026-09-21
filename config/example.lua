-- Edit for your LAN before deployment. DNS routes come from the running config.
-- This is a finite, loopback-only example, not a ready-to-run public DNS service.
return {
  listen_host = "127.0.0.1", listen_port = 53053,
  allowed_clients = {"127.0.0.1"},
  local_dns_host = "127.0.0.1", local_dns_port = 53,
  local_zones = {"home.arpa"},
  cache_entries = 256, cache_bytes = 1048576, cache_ttl_fields = 4096,
  duration = 120, stats_interval = 60,
  console_log = true, syslog = false
}
