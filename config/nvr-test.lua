-- NVR510 ONU compatibility trial v0.1.4-nvr.1; hardware validation pending.
-- Keep the same limits and automatic configuration as the stable release.
return {
  auto_config = true,
  cache_entries = 256, cache_bytes = 1048576, cache_ttl_fields = 4096,
  stats_interval = 60,
  console_log = false, syslog = true
}
