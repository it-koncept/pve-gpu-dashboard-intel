#!/usr/bin/env bash
#
# PVE GPU Dashboard Mod - INTEL EDITION v3.1
# (based on v3.0 by en4ble1337, adapted for Intel iGPU/Arc)
#
# Adds Intel GPU monitoring to the Proxmox VE node dashboard:
#   - GPU utilization bar + metrics (temp/power/freq/RC6)
#   - Engine breakdown (Render/Video/VideoEnhance/Blitter) + memory bandwidth
#   - History charts: Temperature, Utilization, Power, Engine utilization
#
# Data sources: intel_gpu_top -J (util, freq, GPU power via RAPL, engines,
# imc bandwidth, rc6) + coretemp hwmon (CPU package temp - iGPU has no own sensor).
# A systemd sampler writes /var/lib/pve-gpu-intel/status.json every ~5s;
# the PVE API block just reads that file (no per-poll intel_gpu_top cost).
#
# PVE 8.x/9.x. Uninstall restores timestamped backups + removes sampler.
#

################### Configuration #############
TEMP_WARNING=70
TEMP_CRITICAL=85
BACKUP_DIR=""

##################### DO NOT EDIT BELOW #######################
SCRIPT_VERSION="3.2-intel"
PVE_MANAGER_LIB_JS_FILE="/usr/share/pve-manager/js/pvemanagerlib.js"
NODES_PM_FILE="/usr/share/perl5/PVE/API2/Nodes.pm"
SAMPLER_BIN="/usr/local/bin/pve-gpu-intel-sampler"
SAMPLER_UNIT="/etc/systemd/system/pve-gpu-intel-sampler.service"
SAMPLER_DIR="/var/lib/pve-gpu-intel"

function msgb() { echo -e "\e[1m$1\e[0m"; }
function info() { echo -e "\e[0;32m[info] $1\e[0m"; }
function warn() { echo -e "\e[0;33m[warning] $1\e[0m"; }
function err()  { echo -e "\e[0;31m[error] $1\e[0m"; exit 1; }

function usage {
    msgb "\nPVE GPU Dashboard Mod (Intel) v${SCRIPT_VERSION}"
    msgb "\nUsage:\n$0 [install | uninstall]\n"
    exit 1
}

function check_root_privileges() {
    [[ $EUID -eq 0 ]] || err "Must run as root."
    info "Root privileges verified."
}

function check_intel_gpu() {
    if ! lspci 2>/dev/null | grep -Eqi '(VGA|Display|3D controller).*Intel'; then
        err "No Intel GPU found via lspci."
    fi
    if ! command -v intel_gpu_top &>/dev/null; then
        warn "intel_gpu_top not found - installing intel-gpu-tools..."
        apt-get install -y intel-gpu-tools || err "Failed to install intel-gpu-tools."
    fi
    if ! timeout 5 intel_gpu_top -J -s 500 2>/dev/null | grep -q engines; then
        warn "intel_gpu_top test run failed - dashboard will show no data until this works."
    fi
    info "Intel GPU detected, intel_gpu_top available."
}

function check_mod_installation() {
    grep -q 'gpuDriverVersion' "$NODES_PM_FILE" 2>/dev/null && \
        err "A GPU dashboard mod is already installed. Uninstall first."
}

function set_backup_directory() {
    [[ -n "$BACKUP_DIR" ]] || BACKUP_DIR="$HOME/PVE-GPU-DASHBOARD"
    mkdir -p "$BACKUP_DIR" || err "Cannot create $BACKUP_DIR"
}

function create_file_backup() {
    local src="$1" ts="$2" fn
    fn=$(basename "$src")
    local bak="$BACKUP_DIR/gpu-dashboard.${fn}.$ts"
    cp "$src" "$bak" || err "Backup failed: $bak"
    cmp -s "$src" "$bak" || err "Backup verify failed: $bak"
    info "Backup: $bak"
}

function perform_backup() {
    local ts; ts=$(date +%Y%m%d_%H%M%S)
    msgb "\n=== Backing up files to be modified ==="
    set_backup_directory
    create_file_backup "$NODES_PM_FILE" "$ts"
    create_file_backup "$PVE_MANAGER_LIB_JS_FILE" "$ts"
}

function restart_proxy() {
    info "Restarting pveproxy..."
    systemctl restart pveproxy
}

############### Sampler (systemd) ###############
function install_sampler() {
    msgb "\n=== Installing GPU sampler service ==="
    mkdir -p "$SAMPLER_DIR"

    cat > "$SAMPLER_BIN" << 'SAMPLER_PY'
#!/usr/bin/env python3
"""pve-gpu-intel-sampler v3.1: samples Intel GPU stats -> /var/lib/pve-gpu-intel/status.json"""
import json, subprocess, time, glob, os

OUT_DIR = "/var/lib/pve-gpu-intel"
OUT = os.path.join(OUT_DIR, "status.json")

def pkg_temp():
    for h in sorted(glob.glob('/sys/class/hwmon/hwmon*')):
        try:
            if open(h + '/name').read().strip() == 'coretemp':
                return round(int(open(h + '/temp1_input').read()) / 1000.0, 1)
        except Exception:
            pass
    return 0.0

def gpu_name():
    try:
        out = subprocess.run(['lspci'], capture_output=True, text=True, timeout=10).stdout
        for line in out.splitlines():
            if ('VGA compatible' in line or 'Display controller' in line or '3D controller' in line) \
                    and 'Intel' in line:
                return line.split(': ', 2)[-1].strip()
    except Exception:
        pass
    return 'Intel GPU'

def parse_last_json(text):
    """intel_gpu_top -J emits multiple concatenated JSON objects (stdout starts with
    a newline); return the LAST complete object (the first is a startup artifact)."""
    dec = json.JSONDecoder()
    idx, last = 0, None
    while idx < len(text):
        while idx < len(text) and text[idx] in ' \t\r\n':
            idx += 1
        if idx >= len(text):
            break
        try:
            obj, end = dec.raw_decode(text, idx)
            last = obj
            idx = end
        except ValueError:
            break
    return last

NAME = gpu_name()
os.makedirs(OUT_DIR, exist_ok=True)

def read_stream_object(proc):
    """Read one complete JSON object from the line-buffered intel_gpu_top stream.
    Objects end on a line starting with '}' (separator is '},')."""
    buf = ''
    while True:
        line = proc.stdout.readline()
        if not line:
            return None
        buf += line
        if line.startswith('}'):
            try:
                return json.loads(buf.rstrip().rstrip(','))
            except ValueError:
                buf = ''

while True:
    util = freq = power = power_pkg = rc6 = 0.0
    eng = {'render': 0.0, 'video': 0.0, 'videoenhance': 0.0, 'blitter': 0.0}
    bw_r = bw_w = 0.0
    proc = None
    try:
        proc = subprocess.Popen(['stdbuf', '-oL', 'intel_gpu_top', '-J', '-s', '1000'],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        deadline = time.time() + 6
        latest = None
        while time.time() < deadline:
            obj = read_stream_object(proc)
            if obj is None:
                break
            # skip startup artifact objects (period ~0)
            if (obj.get('period') or {}).get('duration', 0) >= 500:
                latest = obj
        if latest:
            busy = [float(e.get('busy', 0)) for e in (latest.get('engines') or {}).values()
                    if isinstance(e, dict)]
            util = round(max(busy), 1) if busy else 0.0
            for name, e in (latest.get('engines') or {}).items():
                if not isinstance(e, dict):
                    continue
                key = name.split('/')[0].lower()
                if key in eng:
                    eng[key] = round(float(e.get('busy', 0)), 1)
            freq = round(float((latest.get('frequency') or {}).get('actual', 0)))
            power = round(float((latest.get('power') or {}).get('GPU', 0)), 2)
            power_pkg = round(float((latest.get('power') or {}).get('Package', 0)), 2)
            rc6 = round(float((latest.get('rc6') or {}).get('value', 0)), 1)
            bw_r = round(float((latest.get('imc-bandwidth') or {}).get('reads', 0)), 1)
            bw_w = round(float((latest.get('imc-bandwidth') or {}).get('writes', 0)), 1)
    except Exception:
        pass
    finally:
        if proc:
            try:
                proc.stdout.close()
            except Exception:
                pass
            try:
                proc.terminate()
                proc.wait(timeout=3)
            except Exception:
                proc.kill()
    data = {'name': NAME, 'temp': pkg_temp(), 'util': util, 'freq': freq,
            'power': power, 'power_pkg': power_pkg, 'rc6': rc6,
            'engines': eng, 'bw_read': bw_r, 'bw_write': bw_w,
            'time': int(time.time())}
    try:
        tmp = OUT + '.tmp'
        with open(tmp, 'w') as f:
            json.dump(data, f)
        os.replace(tmp, OUT)
    except Exception:
        pass
    time.sleep(1)
SAMPLER_PY
    chmod 755 "$SAMPLER_BIN"

    cat > "$SAMPLER_UNIT" << 'UNIT'
[Unit]
Description=PVE Intel GPU sampler for dashboard mod
After=pveproxy.service

[Service]
ExecStart=/usr/local/bin/pve-gpu-intel-sampler
Restart=always
RestartSec=5
Nice=10

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now pve-gpu-intel-sampler
    sleep 8
    if systemctl is-active --quiet pve-gpu-intel-sampler && [[ -f "$SAMPLER_DIR/status.json" ]]; then
        info "Sampler running: $(cat "$SAMPLER_DIR/status.json")"
    else
        err "Sampler service failed to start or produced no data."
    fi
}

############### Backend: Nodes.pm ###############
function insert_node_info() {
    msgb "\n=== Inserting Intel GPU data retrieval into API ==="
    local temp_perl_code="/tmp/gpu_perl_code.txt"

    cat > "$temp_perl_code" << 'PERL_CODE'
# Collect Intel GPU data for dashboard integration (pve-gpu-intel v3.1)
if (-f '/var/lib/pve-gpu-intel/status.json') {
    my $raw = `cat /var/lib/pve-gpu-intel/status.json 2>/dev/null`;
    my $gpu;
    eval { require JSON::PP; $gpu = JSON::PP->new->decode($raw); 1 } or $gpu = undef;
    if ($gpu && (time() - ($gpu->{time} || 0)) < 30) {
        my $name  = $gpu->{name} || 'Intel GPU';
        my $temp  = ($gpu->{temp} || 0) + 0;
        my $util  = ($gpu->{util} || 0) + 0;
        my $power = ($gpu->{power} || 0) + 0;
        my $power_pkg = ($gpu->{power_pkg} || 0) + 0;
        my $freq  = ($gpu->{freq} || 0) + 0;
        my $rc6   = ($gpu->{rc6} || 0) + 0;
        my $eng   = $gpu->{engines} || {};
        my $render = ($eng->{render} || 0) + 0;
        my $video  = ($eng->{video} || 0) + 0;
        my $venh   = ($eng->{videoenhance} || 0) + 0;
        my $blit   = ($eng->{blitter} || 0) + 0;
        my $bw     = int((($gpu->{bw_read} || 0) + ($gpu->{bw_write} || 0)) * 1024 * 1024);
        $res->{gpuDriverVersion} = 'i915';
        $res->{gpu0_name}  = $name;
        $res->{gpu0_temp}  = $temp;
        $res->{gpu0_util}  = $util;
        $res->{gpu0_util_max} = 100;
        $res->{gpu0_mem_util} = 0;
        $res->{gpu0_mem_used} = 0;
        $res->{gpu0_mem_total} = 0;
        $res->{gpu0_power_draw} = $power;
        $res->{gpu0_power_pkg} = $power_pkg;
        $res->{gpu0_power_limit} = 0;
        $res->{gpu0_fan} = -1;
        $res->{gpu0_freq} = $freq;
        $res->{gpu0_rc6} = $rc6;
        $res->{gpu0_render} = $render;
        $res->{gpu0_video} = $video;
        $res->{gpu0_bw} = $bw;
        # Format: temp,util,power_draw,power_limit,fan,freq,rc6,pkg_power
        $res->{"gpu0_metrics"} = "${temp},${util},${power},0,-1,${freq},${rc6},${power_pkg}";
        # Format: render,video,videoenhance,blitter,bw_bytes
        $res->{"gpu0_engines"} = "${render},${video},${venh},${blit},${bw}";
        $res->{gpuCount} = 1;
        $res->{gpu_server_time} = time();
    }
}
PERL_CODE

    perl -i -0777 -pe '
        BEGIN {
            open(my $fh, "<", "/tmp/gpu_perl_code.txt") or die "Cannot open temp file: $!";
            local $/;
            $::code = <$fh>;
            close($fh);
        }
        s/(my \$dinfo = df\(.*?\);)/$::code\n$1/s;
    ' "$NODES_PM_FILE"
    local ec=$?
    rm -f "$temp_perl_code"
    [[ $ec -eq 0 ]] || err "Failed to insert Perl code into Nodes.pm"
    grep -q 'gpuDriverVersion' "$NODES_PM_FILE" || err "Perl insertion verification failed"

    # Perl syntax check: only fail if THIS insertion introduced an error.
    # (perl -c can fail on missing modules even for the untouched file, so
    # compare against the pristine backup as baseline.)
    if ! perl -c "$NODES_PM_FILE" >/dev/null 2>&1; then
        local baseline_bak
        baseline_bak=$(find "$BACKUP_DIR" -name "gpu-dashboard.Nodes.pm.*" -type f -printf '%T+ %p\n' 2>/dev/null | sort -r | head -n 1 | awk '{print $2}')
        if [[ -n "$baseline_bak" ]] && perl -c "$baseline_bak" >/dev/null 2>&1; then
            err "Nodes.pm failed perl -c after insertion (backup compiles clean) - RESTORE BACKUP and investigate."
        else
            warn "perl -c unavailable (missing modules) - skipping syntax gate."
        fi
    else
        info "Nodes.pm Perl syntax OK."
    fi
    info "GPU data retrieval code added to $NODES_PM_FILE."
}

############### Frontend: RRD model fields ###############
function insert_rrd_model_fields() {
    msgb "\n=== Adding GPU fields to RRD data model ==="
    cat > /tmp/gpu_rrd_fields.txt << 'EOF'

        // GPU 0 RRD fields (intel)
        'gpu0_temp',
        'gpu0_util',
        'gpu0_power_draw',
EOF
    perl -i -0777 -pe '
        BEGIN {
            open(my $fh, "<", "/tmp/gpu_rrd_fields.txt") or die "Cannot open temp file: $!";
            local $/;
            $::fields = <$fh>;
            close($fh);
        }
        s/('"'"'swapused'"'"',)/$1$::fields/s;
    ' "$PVE_MANAGER_LIB_JS_FILE"
    rm -f /tmp/gpu_rrd_fields.txt
    grep -q "gpu0_temp" "$PVE_MANAGER_LIB_JS_FILE" || err "RRD model fields insertion failed"
    info "GPU fields added to RRD data model."
}

############### Frontend: history charts ###############
function insert_gpu_history_charts() {
    msgb "\n=== Inserting GPU historical charts ==="
    local nodename; nodename=$(hostname)
    local max_points=1440 poll_interval=60000   # 24h @ 1 min
    local temp_charts_file="/tmp/gpu_history_charts.js"

    cat > "$temp_charts_file" << CHARTS_JS
// GPU History Store - localStorage-backed (pve-gpu-intel v3.1)
Ext.define('PVE.data.GPUHistoryStore', {
    extend: 'Ext.data.Store',
    alias: 'store.pveGPUHistoryStore',
    config: {
        nodename: '',
        gpuIndex: 0,
        maxPoints: ${max_points},
        pollInterval: ${poll_interval}
    },
CHARTS_JS

    cat >> "$temp_charts_file" << 'CHARTS_JS'
    fields: ['time', 'gpu_temp', 'gpu_util', 'gpu_power_draw', 'gpu_power_pkg', 'gpu_render', 'gpu_video'],
    constructor: function(config) {
        var me = this;
        me.callParent([config]);
        me.storageKey = 'pve-gpu-rrd-' + me.getNodename() + '-gpu' + me.getGpuIndex();
        me.loadFromStorage();
        me.startPolling();
    },
    getStorageKey: function() { return this.storageKey; },
    loadFromStorage: function() {
        var me = this;
        try {
            var data = localStorage.getItem(me.storageKey);
            if (data) {
                var records = JSON.parse(data);
                records = records.map(function(rec) {
                    if (rec.time && rec.time < 10000000000) { rec.time = rec.time * 1000; }
                    return rec;
                });
                me.loadData(records);
            }
        } catch(e) { console.warn('GPU history load failed:', e); }
    },
    saveToStorage: function() {
        var me = this;
        try {
            var records = [];
            me.each(function(rec) {
                var data = rec.getData();
                if (data.time && data.time > 10000000000) { data.time = Math.floor(data.time / 1000); }
                records.push(data);
            });
            localStorage.setItem(me.storageKey, JSON.stringify(records));
        } catch(e) { localStorage.removeItem(me.storageKey); }
    },
    addDataPoint: function(temp, util, powerDraw, powerPkg, render, video, serverTime) {
        var me = this;
        me.add({ time: serverTime || Date.now(), gpu_temp: temp, gpu_util: util,
                 gpu_power_draw: powerDraw, gpu_power_pkg: powerPkg,
                 gpu_render: render, gpu_video: video });
        while (me.getCount() > me.getMaxPoints()) { me.removeAt(0); }
        me.saveToStorage();
    },
    startPolling: function() {
        var me = this;
        var poll = function() {
            Proxmox.Utils.API2Request({
                url: '/nodes/' + me.getNodename() + '/status',
                method: 'GET',
                success: function(response) {
                    var data = response.result.data;
                    var gpuIdx = me.getGpuIndex();
                    var temp = data['gpu' + gpuIdx + '_temp'];
                    var serverTime = data.gpu_server_time ? data.gpu_server_time * 1000 : Date.now();
                    if (temp !== undefined) {
                        me.addDataPoint(
                            parseFloat(temp) || 0,
                            parseFloat(data['gpu' + gpuIdx + '_util']) || 0,
                            parseFloat(data['gpu' + gpuIdx + '_power_draw']) || 0,
                            parseFloat(data['gpu' + gpuIdx + '_power_pkg']) || 0,
                            parseFloat(data['gpu' + gpuIdx + '_render']) || 0,
                            parseFloat(data['gpu' + gpuIdx + '_video']) || 0,
                            serverTime);
                    }
                }
            });
        };
        poll();
        me.pollTask = Ext.TaskManager.start({ run: poll, interval: me.getPollInterval() });
    },
    destroy: function() {
        var me = this;
        if (me.pollTask) { Ext.TaskManager.stop(me.pollTask); }
        me.callParent();
    }
});
CHARTS_JS

    perl -i -0777 -pe '
        BEGIN {
            open(my $fh, "<", "/tmp/gpu_history_charts.js") or die "Cannot open charts file: $!";
            local $/;
            $::chartclass = <$fh>;
            close($fh);
        }
        s/(Ext\.define\('"'"'PVE\.node\.Summary'"'"')/$::chartclass\n\n$1/s;
    ' "$PVE_MANAGER_LIB_JS_FILE"

    local temp_instances_file="/tmp/gpu_chart_instances.js"
    cat > "$temp_instances_file" << 'INSTANCES_EOF'
	    // GPU Historical Charts (pve-gpu-intel v3.1)
	    {
	        xtype: 'proxmoxRRDChart',
	        title: 'GPU 0 Temperature (CPU package)',
	        fields: ['gpu_temp'],
	        fieldTitles: ['Package °C'],
	        store: Ext.create('PVE.data.GPUHistoryStore', { nodename: nodename, gpuIndex: 0 })
	    },
	    {
	        xtype: 'proxmoxRRDChart',
	        title: 'GPU 0 Utilization',
	        fields: ['gpu_util'],
	        fieldTitles: ['Utilization %'],
	        store: Ext.create('PVE.data.GPUHistoryStore', { nodename: nodename, gpuIndex: 0 })
	    },
	    {
	        xtype: 'proxmoxRRDChart',
	        title: 'GPU 0 Power Draw',
	        fields: ['gpu_power_draw', 'gpu_power_pkg'],
	        fieldTitles: ['Power GPU (W)', 'Power package (W)'],
	        store: Ext.create('PVE.data.GPUHistoryStore', { nodename: nodename, gpuIndex: 0 })
	    },
	    {
	        xtype: 'proxmoxRRDChart',
	        title: 'GPU 0 Engine Utilization',
	        fields: ['gpu_render', 'gpu_video'],
	        fieldTitles: ['Render/3D %', 'Video %'],
	        store: Ext.create('PVE.data.GPUHistoryStore', { nodename: nodename, gpuIndex: 0 })
	    },
INSTANCES_EOF

    perl -i -0777 -pe '
        BEGIN {
            open(my $fh, "<", "/tmp/gpu_chart_instances.js") or die "Cannot open instances file: $!";
            local $/;
            $::instances = <$fh>;
            close($fh);
        }
        s/(title:\s*gettext\('"'"'Network [Tt]raffic'"'"'\),\s*fields:\s*\['"'"'netin'"'"',\s*'"'"'netout'"'"'\],\s*(?:fieldTitles:\s*\[.*?\],\s*)?store:\s*rrdstore,\s*\},)/$1\n$::instances/s;
    ' "$PVE_MANAGER_LIB_JS_FILE"
    local insert_status=$?
    rm -f "$temp_charts_file" "$temp_instances_file"
    [[ $insert_status -eq 0 ]] || err "Failed to insert GPU history charts"
    grep -q "GPUHistoryStore" "$PVE_MANAGER_LIB_JS_FILE" || err "History charts insertion verification failed"
    info "GPU historical charts inserted (24h @ 1-min, browser localStorage)."
}

############### Frontend: StatusView items ###############
function insert_gpu_dashboard_items() {
    msgb "\n=== Inserting GPU dashboard items into StatusView ==="
    local gpu_name
    gpu_name=$(lspci 2>/dev/null | grep -Ei '(VGA|Display|3D controller).*Intel' | head -1 | sed 's/^.*: //' | xargs)
    local temp_items_file="/tmp/gpu_dashboard_items.js"

    cat > "$temp_items_file" << ITEMS_EOF
	{
	    xtype: 'box',
	    colspan: 2,
	    padding: '0 0 20 0',
	},
	{
	    itemId: 'gpu0_util',
	    iconCls: 'fa fa-fw fa-television',
	    title: 'GPU 0: ${gpu_name} (driver: i915)',
	    valueField: 'gpu0_util',
	    maxField: 'gpu0_util_max',
	},
	{
	    itemId: 'gpu0_metrics',
	    printBar: false,
	    title: 'GPU 0 Metrics',
	    textField: 'gpu0_metrics',
	    renderer: function(value) {
	        if (!value) return 'No GPU data';
	        var parts = value.split(',');
	        if (parts.length < 8) return 'Invalid data';
	        var temp = parseFloat(parts[0]) || 0;
	        var gpuUtil = parseInt(parts[1]) || 0;
	        var powerDraw = parseFloat(parts[2]) || 0;
	        var freq = parseInt(parts[5]) || 0;
	        var rc6 = parseInt(parts[6]) || 0;
	        var powerPkg = parseFloat(parts[7]) || 0;
	        var tempStyle = '';
	        if (temp >= ${TEMP_CRITICAL}) {
	            tempStyle = 'color: #ff4444; font-weight: bold;';
	        } else if (temp >= ${TEMP_WARNING}) {
	            tempStyle = 'color: #FFC300; font-weight: bold;';
	        }
	        var tempStr = '<span style="' + tempStyle + '">' + temp.toFixed(0) + '°C</span>';
	        return 'GPU: ' + gpuUtil + '% | Pkg Temp: ' + tempStr + ' | Power: ' + powerDraw.toFixed(1) + 'W GPU / ' + powerPkg.toFixed(1) + 'W pkg | Freq: ' + freq + ' MHz | RC6: ' + rc6 + '%';
	    },
	},
	{
	    itemId: 'gpu0_engines',
	    printBar: false,
	    title: 'GPU 0 Engines / Bandwidth',
	    textField: 'gpu0_engines',
	    renderer: function(value) {
	        if (!value) return 'No GPU data';
	        var parts = value.split(',');
	        if (parts.length < 5) return 'Invalid data';
	        var render = parseFloat(parts[0]) || 0;
	        var video = parseFloat(parts[1]) || 0;
	        var venh = parseFloat(parts[2]) || 0;
	        var blit = parseFloat(parts[3]) || 0;
	        var bw = parseFloat(parts[4]) || 0;
	        var bwStr = bw >= 1073741824 ? (bw / 1073741824).toFixed(2) + ' GiB/s' : (bw / 1048576).toFixed(0) + ' MiB/s';
	        return 'Render: ' + render.toFixed(0) + '% | Video: ' + video.toFixed(0) + '% | VideoEnh: ' + venh.toFixed(0) + '% | Blitter: ' + blit.toFixed(0) + '% | RAM BW: ' + bwStr;
	    },
	},
ITEMS_EOF

    perl -i -0777 -pe '
        BEGIN {
            open(my $fh, "<", "/tmp/gpu_dashboard_items.js") or die "Cannot open temp file: $!";
            local $/;
            $::items = <$fh>;
            close($fh);
        }
        s/(itemId:\s*'\''swap'\''.*?\n\s*\},)(\s*\{\s*xtype:\s*'\''box'\'',\s*colspan:\s*2,\s*padding:\s*'\''0 0 20 0'\'')/$1$::items$2/s;
    ' "$PVE_MANAGER_LIB_JS_FILE"
    local insert_status=$?
    if [[ $insert_status -ne 0 ]]; then
        rm -f "$temp_items_file"
        err "Failed to insert GPU dashboard items"
    fi
    grep -q "itemId: 'gpu0_util'" "$PVE_MANAGER_LIB_JS_FILE" || { rm -f "$temp_items_file"; err "StatusView items insertion verification failed"; }
    rm -f "$temp_items_file"
    info "GPU dashboard items inserted into StatusView."
}

############### install / uninstall ###############
function install_mod() {
    msgb "\n=== PVE GPU Dashboard Mod (Intel) v${SCRIPT_VERSION} ==="
    check_root_privileges
    check_mod_installation
    check_intel_gpu
    perform_backup
    install_sampler
    insert_node_info
    insert_gpu_dashboard_items
    insert_rrd_model_fields
    insert_gpu_history_charts
    msgb "\n=== Finalizing ==="
    restart_proxy
    info "Installation complete."
    msgb "\nClear browser cache (Ctrl+Shift+R) to see changes."
    echo "  - GPU utilization bar + metrics + engine breakdown in Status section"
    echo "  - History charts (Temp/Util/Power/Engines, 24h @ 1min) below Network traffic"
    echo "  - Sampler: systemctl status pve-gpu-intel-sampler"
}

function uninstall_mod() {
    msgb "\n=== Uninstalling GPU Dashboard Mod (Intel) ==="
    check_root_privileges
    grep -q 'gpuDriverVersion' "$NODES_PM_FILE" 2>/dev/null || err "Mod not installed."
    set_backup_directory

    systemctl disable --now pve-gpu-intel-sampler 2>/dev/null
    rm -f "$SAMPLER_UNIT" "$SAMPLER_BIN"
    rm -rf "$SAMPLER_DIR"
    systemctl daemon-reload
    info "Sampler service removed."

    local latest_nodes_pm latest_js
    latest_nodes_pm=$(find "$BACKUP_DIR" -name "gpu-dashboard.Nodes.pm.*" -type f -printf '%T+ %p\n' 2>/dev/null | sort -r | head -n 1 | awk '{print $2}')
    latest_js=$(find "$BACKUP_DIR" -name "gpu-dashboard.pvemanagerlib.js.*" -type f -printf '%T+ %p\n' 2>/dev/null | sort -r | head -n 1 | awk '{print $2}')
    [[ -n "$latest_nodes_pm" ]] && { cp "$latest_nodes_pm" "$NODES_PM_FILE"; info "Restored Nodes.pm"; } || warn "No Nodes.pm backup."
    [[ -n "$latest_js" ]] && { cp "$latest_js" "$PVE_MANAGER_LIB_JS_FILE"; info "Restored pvemanagerlib.js"; } || warn "No pvemanagerlib.js backup."
    restart_proxy
    info "Uninstall complete. Clear browser cache."
}

executed=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        install) executed=$((executed+1)); install_mod ;;
        uninstall) executed=$((executed+1)); uninstall_mod ;;
        *) warn "Unknown option: $1"; usage ;;
    esac
    shift
done
if [[ $executed -eq 0 ]]; then usage; fi
