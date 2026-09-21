-- Ready-to-run profile: derive DNS access and local names at startup.
-- No site addresses, hostnames, or credentials are stored in this file.
return {
  auto_config = true,
  cache_entries = 256, cache_bytes = 1048576, cache_ttl_fields = 4096,
  stats_interval = 60,
  console_log = false, syslog = true
}
