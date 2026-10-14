# Changelog

## v3.2-intel
- Sampler now runs `intel_gpu_top` as a persistent line-buffered stream process (`stdbuf -oL`) instead of restarting it per cycle — fresher data, less overhead, no reliance on SIGTERM flush behavior.
- Startup-artifact samples (period < 500 ms, power always 0) are skipped.
- Added CPU **package power** (`power.Package` from intel_gpu_top / RAPL): metrics line shows `X W GPU / Y W pkg`, and the Power history chart has both series. Fixes "no watts" on CPUs whose GPU/uncore RAPL domain is dead (e.g. Haswell-ULT).

## v3.1-intel
- Engine breakdown: Render/3D, Video, VideoEnhance, Blitter busy % as a separate StatusView line.
- GPU RAM bandwidth (imc-bandwidth reads+writes) in the engines line.
- RC6 % in the metrics line.
- New history chart: Engine Utilization (Render + Video).

## v3.0-intel
- Initial Intel adaptation of en4ble1337/proxmox-gpu-dashboard v3.0.
- `nvidia-smi` data collection replaced by a systemd sampler around `intel_gpu_top -J` + coretemp hwmon.
- GPU utilization bar replaces the VRAM bar (iGPUs share system RAM).
- Perl syntax gate compares against the pristine backup to avoid false failures from missing modules.
