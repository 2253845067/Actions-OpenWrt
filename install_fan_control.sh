#!/bin/sh

# Cyber 3588 AIB 风扇控制安装脚本 V3.0
# 修复清单:
#   1. 修复 LuCI 菜单不显示 (新版 LuCI 需要 ACL 文件 + acl_depends)
#   2. 修复 CPU 温度读取 (兼容无 thermal_zone 的固件)
#   3. 修复 WiFi 温度读取 (按 hwmon 名称匹配, 区分 2.4G/5G)
#   4. 修复 modem_temp 带 "°C" 后缀导致 PID 比较报错
#   5. 修复 SSD 温度读取 (兼容 eMMC, 尝试 -d sat)
#   6. 修复 init 脚本 stop() 使用 pkill (busybox 无 pkill)
#   7. 添加 .leaf = true 防止子路由干扰菜单结构
#   8. 添加 safe_max() 安全比较函数, 避免 "unknown operand" 错误
# PWM: /sys/class/pwm/pwmchip0/pwm0 (period=50000ns, polarity=normal)

# ==================== 清理旧版本 ====================
echo "清理旧版本文件..."
/etc/init.d/fancontrol stop 2>/dev/null
/etc/init.d/fancontrol disable 2>/dev/null
# 兼容无 pkill 的系统
for pid in $(ps | grep "/usr/bin/fan_control" | grep -v grep | awk '{print $1}'); do
    kill $pid 2>/dev/null
done
rm -f /usr/bin/sensors_monitor
rm -f /usr/bin/set_fan_speed
rm -f /usr/bin/fan_control
rm -f /usr/lib/lua/luci/controller/sensors.lua
rm -f /usr/lib/lua/luci/view/sensors_monitor.htm
rm -f /etc/fan_target
rm -f /etc/fan_config
rm -f /etc/init.d/fancontrol

# ==================== 创建传感器监控脚本 ====================
echo "创建传感器监控脚本..."
cat << 'INNER_EOF' > /usr/bin/sensors_monitor
#!/bin/sh

PWM_PATH="/sys/class/pwm/pwmchip0/pwm0"

# 从 hwmon 设备名查找对应路径
find_hwmon_by_name() {
    for h in /sys/class/hwmon/hwmon*; do
        name=$(cat "$h/name" 2>/dev/null)
        if [ "$name" = "$1" ]; then
            echo "$h"
            return 0
        fi
    done
    return 1
}

# 提取纯数字温度值（去除°C等单位后缀）
extract_temp() {
    echo "$1" | grep -oE '[0-9]+' | head -1
}

# 采集数据并转换为JSON格式
{
  echo "{"

  # CPU温度 - 尝试多个路径
  cpu_temp=""
  for path in \
      /sys/class/thermal/thermal_zone0/temp \
      /sys/devices/virtual/thermal/thermal_zone0/temp; do
      val=$(cat "$path" 2>/dev/null)
      if [ -n "$val" ] && [ "$val" -gt 0 ] 2>/dev/null; then
          cpu_temp=$((val/1000))
          break
      fi
  done
  [ -n "$cpu_temp" ] && echo "\"cpu_temp\": \"$cpu_temp\"," || echo "\"cpu_temp\": \"N/A\","

  # 5GHz WiFi温度 (mt7915_phy0 = hwmon2)
  wifi5_hwmon=$(find_hwmon_by_name "mt7915_phy0")
  if [ -n "$wifi5_hwmon" ]; then
      wifi5_raw=$(cat "$wifi5_hwmon/temp1_input" 2>/dev/null)
      [ -n "$wifi5_raw" ] && wifi5_temp=$((wifi5_raw/1000)) || wifi5_temp="N/A"
  else
      wifi5_temp="N/A"
  fi
  echo "\"wifi5_temp\": \"$wifi5_temp\","

  # 2.4GHz WiFi温度 (mt7915_phy1 = hwmon3)
  wifi2_hwmon=$(find_hwmon_by_name "mt7915_phy1")
  if [ -n "$wifi2_hwmon" ]; then
      wifi2_raw=$(cat "$wifi2_hwmon/temp1_input" 2>/dev/null)
      [ -n "$wifi2_raw" ] && wifi2_temp=$((wifi2_raw/1000)) || wifi2_temp="N/A"
  else
      wifi2_temp="N/A"
  fi
  echo "\"wifi2_temp\": \"$wifi2_temp\","

  # SSD/eMMC温度 - 尝试NVMe和eMMC
  ssd_temp=""
  if [ -e /dev/nvme0 ]; then
      ssd_temp=$(smartctl -A /dev/nvme0 2>/dev/null | awk '/Temperature:/ {print $2}')
  elif [ -e /dev/mmcblk0 ]; then
      ssd_temp=$(smartctl -d sat -A /dev/mmcblk0 2>/dev/null | awk '/Temperature:/ {print $2}')
  fi
  [ -n "$ssd_temp" ] || ssd_temp="N/A"
  echo "\"ssd_temp\": \"$ssd_temp\","

  # 5G模组温度 - 提取纯数字
  modem_raw=$(/usr/libexec/rpcd/modem_ctrl call info 2>/dev/null | \
              grep -A1 '"key": "temperature"' | \
              grep '"value":' | \
              cut -d'"' -f4)
  modem_temp=$(extract_temp "$modem_raw")
  [ -n "$modem_temp" ] || modem_temp="N/A"
  echo "\"modem_temp\": \"$modem_temp\","

  # 计算最高温度（只比较有效数字）
  max_temp=0
  for temp in "$cpu_temp" "$wifi5_temp" "$wifi2_temp" "$ssd_temp" "$modem_temp"; do
    if [ "$temp" != "N/A" ] && [ -n "$temp" ] && [ "$temp" -gt "$max_temp" ] 2>/dev/null; then
      max_temp=$temp
    fi
  done
  echo "\"max_temp\": \"$max_temp\","

  # 风扇转速 - 从 raw sysfs duty_cycle 读取并转换为百分比
  pwm_period=50000
  fan_invert=0
  if [ -f "/etc/fan_config" ]; then
    cfg_period=$(grep "^pwm_period=" /etc/fan_config | cut -d'=' -f2)
    [ -n "$cfg_period" ] && pwm_period=$cfg_period
    cfg_invert=$(grep "^fan_invert=" /etc/fan_config | cut -d'=' -f2)
    [ -n "$cfg_invert" ] && fan_invert=$cfg_invert
  fi

  fan_duty=$(cat "$PWM_PATH/duty_cycle" 2>/dev/null)
  if [ -n "$fan_duty" ] && [ "$fan_duty" -ge 0 ] 2>/dev/null; then
    if [ "$fan_invert" = "1" ]; then
      fan_percent=$(( 100 - ((fan_duty * 100) / pwm_period) ))
    else
      fan_percent=$(( (fan_duty * 100) / pwm_period ))
    fi
    echo "\"fan_percent\": \"$fan_percent\","
  else
    echo "\"fan_percent\": \"0\","
  fi

  # 添加风扇配置信息
  if [ -f "/etc/fan_config" ]; then
    source /etc/fan_config
    echo "\"fan_target_temp\": \"$target_temp\","
    echo "\"fan_mode\": \"$mode\","
    echo "\"kp\": \"$kp\","
    echo "\"ki\": \"$ki\","
    echo "\"kd\": \"$kd\","
    echo "\"cycle\": \"$cycle\""
  else
    echo "\"fan_target_temp\": \"55\","
    echo "\"fan_mode\": \"auto\","
    echo "\"kp\": \"5.0\","
    echo "\"ki\": \"0.1\","
    echo "\"kd\": \"1.0\","
    echo "\"cycle\": \"10\""
  fi

  echo "}"
} | tr -d '\n'
INNER_EOF
chmod +x /usr/bin/sensors_monitor

# ==================== 创建风扇转速设置脚本 ====================
echo "创建风扇转速设置脚本..."
cat << 'INNER_EOF' > /usr/bin/set_fan_speed
#!/bin/sh

# 检查参数
if [ -z "$1" ]; then
  echo "Usage: $0 <percentage>"
  exit 1
fi

percent=$1
# 严格数字检查
if ! echo "$percent" | grep -qE '^[-+]?[0-9]+$'; then
  echo "Error: Percentage must be a number"
  exit 1
fi
if [ "$percent" -lt 0 ] || [ "$percent" -gt 100 ]; then
  echo "Error: Percentage must be between 0 and 100"
  exit 1
fi

# 从配置文件读取 PWM period 和反转设置
pwm_period=50000
fan_invert=0
if [ -f "/etc/fan_config" ]; then
    cfg_period=$(grep "^pwm_period=" /etc/fan_config | cut -d'=' -f2)
    [ -n "$cfg_period" ] && pwm_period=$cfg_period
    cfg_invert=$(grep "^fan_invert=" /etc/fan_config | cut -d'=' -f2)
    [ -n "$cfg_invert" ] && fan_invert=$cfg_invert
fi

# 将百分比转换为 duty_cycle (纳秒)
# fan_invert=1 时反转: 100% -> duty_cycle=0 (最大转速), 0% -> duty_cycle=period (最小转速)
if [ "$fan_invert" = "1" ]; then
  duty_cycle=$(( pwm_period - (percent * pwm_period / 100) ))
else
  duty_cycle=$(( percent * pwm_period / 100 ))
fi

# PWM sysfs 路径
PWM_PATH="/sys/class/pwm/pwmchip0/pwm0"

if [ -d "$PWM_PATH" ] && [ -w "$PWM_PATH/duty_cycle" ]; then
  echo $duty_cycle > "$PWM_PATH/duty_cycle"
  echo "Fan speed set to $percent% (duty_cycle: $duty_cycle ns)"
else
  echo "Error: PWM sysfs path not found or not writable"
  exit 1
fi
INNER_EOF
chmod +x /usr/bin/set_fan_speed

# ==================== 创建 PID 温控脚本 ====================
echo "创建 PID 温控脚本..."
cat << 'INNER_EOF' > /usr/bin/fan_control
#!/bin/sh

# 加载配置
if [ -f "/etc/fan_config" ]; then
    source /etc/fan_config
else
    target_temp=55
    min_speed=20
    max_speed=100
    mode="auto"
    kp=5.0
    ki=0.1
    kd=1.0
    cycle=10
    pwm_period=50000
fi

PWM_PATH="/sys/class/pwm/pwmchip0/pwm0"

# 确保 PWM 控制路径可用
ensure_pwm_control() {
    if [ ! -d "$PWM_PATH" ]; then
        echo "ERROR: PWM path $PWM_PATH not found (pwm_fan module may still be loaded)"
        return 1
    fi
    if [ ! -w "$PWM_PATH/duty_cycle" ]; then
        echo "ERROR: $PWM_PATH/duty_cycle not writable"
        return 1
    fi
    return 0
}

# 从 hwmon 设备名查找对应路径
find_hwmon_by_name() {
    for h in /sys/class/hwmon/hwmon*; do
        name=$(cat "$h/name" 2>/dev/null)
        if [ "$name" = "$1" ]; then
            echo "$h"
            return 0
        fi
    done
    return 1
}

# 提取纯数字温度值
extract_temp() {
    echo "$1" | grep -oE '[0-9]+' | head -1
}

# 安全比较：仅在值是数字时比较，否则返回旧值
safe_max() {
    if [ "$1" != "N/A" ] && [ -n "$1" ] && [ "$1" -gt "$2" ] 2>/dev/null; then
        echo "$1"
    else
        echo "$2"
    fi
}

# PID状态变量
last_error=0
integral=0

# 获取最高温度
get_max_temp() {
    # CPU温度
    cpu_temp=""
    for path in \
        /sys/class/thermal/thermal_zone0/temp \
        /sys/devices/virtual/thermal/thermal_zone0/temp; do
        val=$(cat "$path" 2>/dev/null)
        if [ -n "$val" ] && [ "$val" -gt 0 ] 2>/dev/null; then
            cpu_temp=$((val/1000))
            break
        fi
    done

    # 5GHz WiFi温度
    wifi5_hwmon=$(find_hwmon_by_name "mt7915_phy0")
    if [ -n "$wifi5_hwmon" ]; then
        wifi5_raw=$(cat "$wifi5_hwmon/temp1_input" 2>/dev/null)
        [ -n "$wifi5_raw" ] && wifi5_temp=$((wifi5_raw/1000)) || wifi5_temp="N/A"
    else
        wifi5_temp="N/A"
    fi

    # 2.4GHz WiFi温度
    wifi2_hwmon=$(find_hwmon_by_name "mt7915_phy1")
    if [ -n "$wifi2_hwmon" ]; then
        wifi2_raw=$(cat "$wifi2_hwmon/temp1_input" 2>/dev/null)
        [ -n "$wifi2_raw" ] && wifi2_temp=$((wifi2_raw/1000)) || wifi2_temp="N/A"
    else
        wifi2_temp="N/A"
    fi

    # SSD/eMMC温度
    ssd_temp=""
    if [ -e /dev/nvme0 ]; then
        ssd_temp=$(smartctl -A /dev/nvme0 2>/dev/null | awk '/Temperature:/ {print $2}')
    elif [ -e /dev/mmcblk0 ]; then
        ssd_temp=$(smartctl -d sat -A /dev/mmcblk0 2>/dev/null | awk '/Temperature:/ {print $2}')
    fi
    [ -n "$ssd_temp" ] || ssd_temp="N/A"

    # 5G模组温度 - 提取纯数字
    modem_raw=$(/usr/libexec/rpcd/modem_ctrl call info 2>/dev/null | \
                grep -A1 '"key": "temperature"' | \
                grep '"value":' | \
                cut -d'"' -f4)
    modem_temp=$(extract_temp "$modem_raw")
    [ -n "$modem_temp" ] || modem_temp="N/A"

    # 安全计算最高温度
    max_temp=0
    max_temp=$(safe_max "$cpu_temp" "$max_temp")
    max_temp=$(safe_max "$wifi5_temp" "$max_temp")
    max_temp=$(safe_max "$wifi2_temp" "$max_temp")
    max_temp=$(safe_max "$ssd_temp" "$max_temp")
    max_temp=$(safe_max "$modem_temp" "$max_temp")

    echo "$max_temp"
}

# 使用 awk 进行浮点计算 (busybox自带，无需额外安装)
calc() {
    awk "BEGIN { printf \"%.3f\", $1 }"
}

# 主循环
while true; do
    # 每次循环重新加载配置
    if [ -f "/etc/fan_config" ]; then
        source /etc/fan_config
    fi

    # 确保 PWM 可控
    if ! ensure_pwm_control; then
        sleep "$cycle"
        continue
    fi

    if [ "$mode" = "auto" ]; then
        current_temp=$(get_max_temp)

        # 如果所有温度都读取失败，跳过本轮
        if [ -z "$current_temp" ] || [ "$current_temp" -eq 0 ] 2>/dev/null; then
            sleep "$cycle"
            continue
        fi

        # PID 计算
        error=$(calc "$current_temp - $target_temp")
        P=$(calc "$kp * $error")
        integral=$(calc "$integral + $ki * $error")
        derivative=$(calc "$error - $last_error")
        D=$(calc "$kd * $derivative")

        # 计算输出
        output=$(calc "$P + $integral + $D")
        output_int=$(printf "%.0f" "$output")

        # 限制范围并抗积分饱和
        if [ "$output_int" -lt "$min_speed" ] 2>/dev/null; then
            speed=$min_speed
            integral=0
        elif [ "$output_int" -gt "$max_speed" ] 2>/dev/null; then
            speed=$max_speed
            integral=0
        else
            speed=$output_int
        fi

        last_error=$error

        /usr/bin/set_fan_speed "$speed" >/dev/null 2>&1
    fi

    sleep "$cycle"
done
INNER_EOF
chmod +x /usr/bin/fan_control

# ==================== 创建 LuCI 控制器 ====================
echo "创建 LuCI 控制器..."
cat << 'INNER_EOF' > /usr/lib/lua/luci/controller/sensors.lua
module("luci.controller.sensors", package.seeall)

function index()
    if not nixio.fs.access("/etc/fan_config") then
        return
    end

    local page = entry({"admin", "status", "sensors"}, template("sensors_monitor"), _("硬件监控"), 90)
    page.dependent = true
    page.acl_depends = { "luci-app-sensors" }

    entry({"admin", "status", "sensors", "data"}, call("action_data")).leaf = true
    entry({"admin", "status", "sensors", "setfan"}, call("action_setfan")).leaf = true
    entry({"admin", "status", "sensors", "settemp"}, call("action_settemp")).leaf = true
    entry({"admin", "status", "sensors", "setmode"}, call("action_setmode")).leaf = true
    entry({"admin", "status", "sensors", "setpid"}, call("action_setpid")).leaf = true
end

function action_data()
    luci.http.prepare_content("application/json")
    luci.http.write(luci.sys.exec("/usr/bin/sensors_monitor"))
end

function action_setfan()
    local fan_percent = luci.http.formvalue("fan_percent")
    local n = tonumber(fan_percent)
    if n and n >= 0 and n <= 100 then
        os.execute("sed -i 's/^mode=.*/mode=manual/' /etc/fan_config")
        local result = luci.sys.exec("/usr/bin/set_fan_speed " .. tostring(math.floor(n)))
        luci.http.prepare_content("application/json")
        luci.http.write('{"result": "success", "message": "' .. result:gsub('"', '\\"'):gsub("\n", "") .. '"}')
    else
        luci.http.status(400, "Invalid parameter")
        luci.http.prepare_content("application/json")
        luci.http.write('{"result": "error", "message": "Invalid fan percentage"}')
    end
end

function action_settemp()
    local target_temp = luci.http.formvalue("target_temp")
    local n = tonumber(target_temp)
    if n and n >= 40 and n <= 80 then
        os.execute("sed -i 's/^target_temp=.*/target_temp=" .. tostring(math.floor(n)) .. "/' /etc/fan_config")
        luci.http.prepare_content("application/json")
        luci.http.write('{"result": "success", "message": "Target temperature set to ' .. tostring(math.floor(n)) .. '"}')
    else
        luci.http.status(400, "Invalid parameter")
        luci.http.prepare_content("application/json")
        luci.http.write('{"result": "error", "message": "Invalid temperature value"}')
    end
end

function action_setmode()
    local mode = luci.http.formvalue("mode")
    if mode == "auto" or mode == "manual" then
        os.execute("sed -i 's/^mode=.*/mode=" .. mode .. "/' /etc/fan_config")

        if mode == "manual" then
            local fan_percent = luci.http.formvalue("fan_percent")
            local n = tonumber(fan_percent)
            if n and n >= 0 and n <= 100 then
                os.execute("/usr/bin/set_fan_speed " .. tostring(math.floor(n)))
            end
        end

        luci.http.prepare_content("application/json")
        luci.http.write('{"result": "success", "message": "Mode set to ' .. mode .. '"}')
    else
        luci.http.status(400, "Invalid parameter")
        luci.http.prepare_content("application/json")
        luci.http.write('{"result": "error", "message": "Invalid mode"}')
    end
end

function action_setpid()
    local kp = luci.http.formvalue("kp")
    local ki = luci.http.formvalue("ki")
    local kd = luci.http.formvalue("kd")
    local cycle = luci.http.formvalue("cycle")

    local nkp = tonumber(kp)
    local nki = tonumber(ki)
    local nkd = tonumber(kd)
    local ncycle = tonumber(cycle)

    if nkp and nki and nkd and ncycle
       and nkp >= 0.1 and nkp <= 20
       and nki >= 0.01 and nki <= 5
       and nkd >= 0 and nkd <= 10
       and ncycle >= 1 and ncycle <= 10 then
        os.execute("sed -i 's/^kp=.*/kp=" .. tostring(nkp) .. "/' /etc/fan_config")
        os.execute("sed -i 's/^ki=.*/ki=" .. tostring(nki) .. "/' /etc/fan_config")
        os.execute("sed -i 's/^kd=.*/kd=" .. tostring(nkd) .. "/' /etc/fan_config")
        os.execute("sed -i 's/^cycle=.*/cycle=" .. tostring(math.floor(ncycle)) .. "/' /etc/fan_config")

        luci.http.prepare_content("application/json")
        luci.http.write('{"result": "success", "message": "PID parameters updated"}')
    else
        luci.http.status(400, "Invalid parameter")
        luci.http.prepare_content("application/json")
        luci.http.write('{"result": "error", "message": "Invalid PID parameters"}')
    end
end
INNER_EOF

# ==================== 创建 LuCI ACL 权限文件 ====================
echo "创建 LuCI ACL 权限文件..."
cat << 'INNER_EOF' > /usr/share/rpcd/acl.d/luci-app-sensors.json
{
	"luci-app-sensors": {
		"description": "Grant access for hardware monitoring and fan control",
		"read": {
			"file": {
				"/usr/bin/sensors_monitor": [ "exec" ]
			},
			"ubus": {
				"file": [ "exec", "stat" ]
			}
		},
		"write": {
			"file": {
				"/usr/bin/set_fan_speed": [ "exec" ]
			},
			"ubus": {
				"file": [ "exec" ]
			}
		}
	}
}
INNER_EOF

# ==================== 创建 LuCI 视图模板 ====================
mkdir -p /usr/lib/lua/luci/view
echo "创建 LuCI 视图模板..."
cat << 'INNER_EOF' > /usr/lib/lua/luci/view/sensors_monitor.htm
<%+header%>

<style>
.sensors-container {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
    gap: 20px;
    padding: 15px;
}
.sensor-card {
    background: #ffffff;
    border-radius: 10px;
    padding: 20px;
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.08);
    color: #333;
    border: 1px solid #eaeaea;
    position: relative;
    overflow: hidden;
}
.card-header {
    display: flex;
    align-items: center;
    margin-bottom: 15px;
    border-bottom: 1px solid #f0f0f0;
    padding-bottom: 12px;
    position: relative;
    z-index: 2;
}
.card-icon {
    font-size: 24px;
    margin-right: 12px;
    width: 44px;
    height: 44px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: #f8f9fa;
    border-radius: 10px;
    color: #4a6cf7;
}
.card-title { font-size: 16px; font-weight: 600; color: #555; }
.card-value-container {
    position: relative;
    height: 100px;
    display: flex;
    align-items: center;
    justify-content: center;
}
.card-value {
    font-size: 32px;
    font-weight: 700;
    text-align: center;
    margin: 15px 0;
    font-family: 'Courier New', monospace;
    position: relative;
    z-index: 2;
}
.card-unit { font-size: 16px; font-weight: 400; color: #777; }
.temp-low { color: #3498db; }
.temp-medium { color: #f39c12; }
.temp-high { color: #e74c3c; }
.fan-card {
    grid-column: 1 / -1;
    background: #f8f9ff;
    border-top: 3px solid #4a6cf7;
}
.fan-card .card-icon { background: #eef2ff; color: #4a6cf7; }
.refresh-info {
    text-align: center;
    padding: 15px;
    color: #777;
    font-size: 14px;
    background: #f9f9f9;
    border-radius: 8px;
    margin: 0 15px;
    border: 1px solid #eee;
}
.status-indicator {
    display: inline-block;
    width: 10px;
    height: 10px;
    border-radius: 50%;
    margin-right: 8px;
    background-color: #2ecc71;
}
.fan-control-container { width: 100%; padding: 10px 0; margin-top: 15px; position: relative; z-index: 2; }
.fan-slider-container { display: flex; align-items: center; gap: 15px; margin-bottom: 15px; }
.fan-slider {
    flex-grow: 1; height: 30px; -webkit-appearance: none; appearance: none;
    background: #e0e0e0; border-radius: 15px; outline: none;
}
.fan-slider::-webkit-slider-thumb {
    -webkit-appearance: none; appearance: none; width: 30px; height: 30px;
    border-radius: 50%; background: #4a6cf7; cursor: pointer; box-shadow: 0 2px 6px rgba(0,0,0,0.2);
}
.fan-slider::-moz-range-thumb {
    width: 30px; height: 30px; border-radius: 50%; background: #4a6cf7;
    cursor: pointer; border: none; box-shadow: 0 2px 6px rgba(0,0,0,0.2);
}
.fan-slider-value { min-width: 40px; text-align: center; font-weight: bold; font-size: 16px; color: #4a6cf7; }
.temp-control-container {
    display: flex; flex-wrap: wrap; gap: 15px; margin-top: 20px;
    background: #f0f5ff; padding: 15px; border-radius: 8px;
}
.temp-control-item { flex: 1; min-width: 200px; }
.temp-control-label { display: block; margin-bottom: 8px; font-weight: 500; color: #555; }
.temp-input { width: 100%; padding: 10px; border: 1px solid #ddd; border-radius: 6px; font-size: 16px; }
.temp-set-btn {
    background: #4a6cf7; color: white; border: none; padding: 10px 20px;
    border-radius: 6px; cursor: pointer; font-weight: 500; transition: background 0.3s;
}
.temp-set-btn:hover { background: #3a5ad8; }
.mode-switch { display: flex; gap: 10px; margin-top: 10px; }
.mode-btn {
    flex: 1; padding: 10px; border: 1px solid #ddd; border-radius: 6px;
    background: #f8f9fa; text-align: center; cursor: pointer; transition: all 0.3s;
}
.mode-btn.active { background: #4a6cf7; color: white; border-color: #4a6cf7; }
.max-temp-card { grid-column: 1 / -1; background: #fff8f0; border-top: 3px solid #ff9800; }
.max-temp-card .card-icon { background: #fff4e6; color: #ff9800; }
.pid-panel {
    margin-top: 20px; background: #f8f9ff; border-radius: 8px;
    padding: 15px; border: 1px solid #e0e0ff;
}
.pid-toggle {
    display: flex; justify-content: space-between; align-items: center; cursor: pointer;
    padding: 10px; background: #eef2ff; border-radius: 6px;
}
.pid-toggle:hover { background: #e0e8ff; }
.pid-title { font-weight: 600; color: #4a6cf7; }
.pid-content { padding: 15px; display: none; }
.pid-content.active { display: block; }
.pid-controls { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 15px; margin-top: 10px; }
.pid-control { display: flex; flex-direction: column; }
.pid-label { margin-bottom: 5px; font-weight: 500; color: #555; }
.pid-input { padding: 10px; border: 1px solid #ddd; border-radius: 6px; font-size: 16px; }
.pid-set-btn {
    background: #4a6cf7; color: white; border: none; padding: 10px; border-radius: 6px;
    cursor: pointer; font-weight: 500; transition: background 0.3s; margin-top: 20px; width: 100%;
}
.pid-set-btn:hover { background: #3a5ad8; }
@media (max-width: 768px) {
    .sensors-container { grid-template-columns: 1fr; }
    .temp-control-container { flex-direction: column; }
    .pid-controls { grid-template-columns: 1fr; }
}
.version-info {
    position: fixed; bottom: 10px; right: 10px; font-size: 12px;
    color: #999; background: rgba(255,255,255,0.8); padding: 2px 5px; border-radius: 3px;
}
.chart-bg {
    position: absolute; top: 0; left: 0; width: 100%; height: 100%;
    z-index: 1; opacity: 0.5;
}
</style>

<div class="cbi-map">
    <h2 name="content"><%:硬件状态监控 V3.0%></h2>
    <div class="cbi-map-descr"><%:实时设备传感器数据 - 每秒自动刷新%></div>
    <div class="sensors-container" id="sensors-container">
        <div class="sensor-card">
            <div class="card-header">
                <div class="card-icon">&#x1F321;</div>
                <div class="card-title">正在加载数据...</div>
            </div>
            <div class="card-value-container">
                <canvas class="chart-bg" id="chart-bg-placeholder"></canvas>
                <div class="card-value">--</div>
            </div>
        </div>
    </div>
    <div class="refresh-info">
        <span id="refresh-status">
            <span class="status-indicator"></span>
            <span>实时更新中 - 最后刷新: <span id="last-update">--:--:--</span></span>
        </span>
    </div>
</div>
<div class="version-info">V3.0 Optimized</div>

<script>
const sensors = [
    { id: "cpu_temp", name: "CPU温度", unit: "\u2103", icon: "\uD83D\uDD25", type: "temp" },
    { id: "wifi5_temp", name: "5GHz WiFi", unit: "\u2103", icon: "\uD83D\uDCF6", type: "temp" },
    { id: "wifi2_temp", name: "2.4GHz WiFi", unit: "\u2103", icon: "\uD83D\uDCF1", type: "temp" },
    { id: "ssd_temp", name: "SSD温度", unit: "\u2103", icon: "\uD83D\uDCBD", type: "temp" },
    { id: "modem_temp", name: "5G模组温度", unit: "\u2103", icon: "\uD83D\uDCF6", type: "temp" },
    { id: "max_temp", name: "最高温度", unit: "\u2103", icon: "\uD83D\uDCC8", type: "temp", class: "max-temp-card" },
    { id: "fan_percent", name: "风扇转速", unit: "%", icon: "\uD83C\uDF00", type: "fan", class: "fan-card" }
];
const historyData = {};
sensors.forEach(sensor => { historyData[sensor.id] = []; });
const container = document.getElementById('sensors-container');
const lastUpdateEl = document.getElementById('last-update');

function initCards() {
    container.innerHTML = '';
    sensors.forEach(sensor => {
        const card = document.createElement('div');
        card.className = 'sensor-card ' + (sensor.class || '');
        card.id = 'card-' + sensor.id;
        if (sensor.type === 'fan') {
            card.innerHTML = '<div class="card-header"><div class="card-icon">' + sensor.icon + '</div><div class="card-title">' + sensor.name + '</div></div>' +
                '<div class="card-value-container"><canvas class="chart-bg" id="chart-' + sensor.id + '"></canvas><div class="card-value">--</div></div>' +
                '<div class="fan-control-container"><div class="fan-slider-container"><span>手动转速:</span>' +
                '<input type="range" min="0" max="100" value="0" class="fan-slider" id="fan-slider"><span class="fan-slider-value" id="fan-slider-value">0%</span></div>' +
                '<div class="temp-control-container"><div class="temp-control-item"><label class="temp-control-label">目标温度 (\u2103)</label>' +
                '<input type="number" min="40" max="80" value="55" class="temp-input" id="target-temp-input"><button class="temp-set-btn" onclick="setTargetTemp()">设置</button></div>' +
                '<div class="temp-control-item"><label class="temp-control-label">工作模式</label><div class="mode-switch">' +
                '<div class="mode-btn" data-mode="auto" onclick="setMode(\'auto\')">自动温控</div><div class="mode-btn" data-mode="manual" onclick="setMode(\'manual\')">手动控制</div></div></div></div>' +
                '<div id="fan-status">当前模式: <span id="current-mode">--</span> | 目标温度: <span id="current-temp">--</span>\u2103</div>' +
                '<div class="pid-panel"><div class="pid-toggle" onclick="togglePidPanel()"><span class="pid-title">PID参数设置</span><span id="pid-toggle-icon">\u25BC</span></div>' +
                '<div class="pid-content" id="pid-content"><div class="pid-controls">' +
                '<div class="pid-control"><label class="pid-label">比例系数 (Kp)</label><input type="number" step="0.1" min="0.1" max="20" class="pid-input" id="kp-input"></div>' +
                '<div class="pid-control"><label class="pid-label">积分系数 (Ki)</label><input type="number" step="0.01" min="0.01" max="5" class="pid-input" id="ki-input"></div>' +
                '<div class="pid-control"><label class="pid-label">微分系数 (Kd)</label><input type="number" step="0.1" min="0" max="10" class="pid-input" id="kd-input"></div>' +
                '<div class="pid-control"><label class="pid-label">控制周期 (秒)</label><input type="number" min="1" max="10" class="pid-input" id="cycle-input"></div>' +
                '</div><button class="pid-set-btn" onclick="setPidParams()">保存PID设置</button></div></div></div>';
        } else {
            card.innerHTML = '<div class="card-header"><div class="card-icon">' + sensor.icon + '</div><div class="card-title">' + sensor.name + '</div></div>' +
                '<div class="card-value-container"><canvas class="chart-bg" id="chart-' + sensor.id + '"></canvas><div class="card-value">--</div></div>';
        }
        container.appendChild(card);
    });
    var fanSlider = document.getElementById('fan-slider');
    if (fanSlider) {
        fanSlider.addEventListener('input', function() { document.getElementById('fan-slider-value').textContent = this.value + '%'; });
        fanSlider.addEventListener('change', function() { setFanSpeed(this.value); });
    }
}

function drawChart(canvasId, values, maxValue, minValue) {
    var canvas = document.getElementById(canvasId);
    if (!canvas) return;
    var ctx = canvas.getContext('2d');
    var width = canvas.width, height = canvas.height;
    ctx.clearRect(0, 0, width, height);
    ctx.strokeStyle = '#4a6cf7'; ctx.lineWidth = 2; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
    ctx.beginPath();
    var pointCount = values.length;
    if (pointCount < 2) return;
    var stepX = width / (pointCount - 1);
    for (var i = 0; i < pointCount; i++) {
        var v = (values[i] === 'N/A' || isNaN(values[i])) ? minValue : Math.min(Math.max(values[i], minValue), maxValue);
        var x = i * stepX;
        var y = height - ((v - minValue) / (maxValue - minValue)) * height;
        if (i === 0) { ctx.moveTo(x, y); }
        else {
            var prevX = (i - 1) * stepX;
            var prevV = (values[i-1] === 'N/A' || isNaN(values[i-1])) ? minValue : Math.min(Math.max(values[i-1], minValue), maxValue);
            var prevY = height - ((prevV - minValue) / (maxValue - minValue)) * height;
            ctx.quadraticCurveTo((prevX + x) / 2, prevY, x, y);
        }
    }
    ctx.stroke();
}

function setFanSpeed(percent) {
    var xhr = new XMLHttpRequest();
    xhr.open('POST', '<%=url("admin/status/sensors/setfan")%>');
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
    xhr.onload = function() { if (xhr.status === 200) { try { var r = JSON.parse(xhr.responseText); console.log(r.message); } catch(e) {} } };
    xhr.send('fan_percent=' + encodeURIComponent(percent));
}

function setTargetTemp() {
    var tempValue = document.getElementById('target-temp-input').value;
    if (!tempValue || tempValue < 40 || tempValue > 80) { alert('请输入有效的温度值 (40-80\u2103)'); return; }
    var xhr = new XMLHttpRequest();
    xhr.open('POST', '<%=url("admin/status/sensors/settemp")%>');
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
    xhr.onload = function() { if (xhr.status === 200) { try { var r = JSON.parse(xhr.responseText); if (r.result === 'success') document.getElementById('current-temp').textContent = tempValue; } catch(e) {} } };
    xhr.send('target_temp=' + encodeURIComponent(tempValue));
}

function setMode(mode) {
    document.querySelectorAll('.mode-btn').forEach(function(btn) { btn.classList.toggle('active', btn.dataset.mode === mode); });
    var fanSpeed = mode === 'manual' ? document.getElementById('fan-slider').value : '0';
    var xhr = new XMLHttpRequest();
    xhr.open('POST', '<%=url("admin/status/sensors/setmode")%>');
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
    xhr.onload = function() { if (xhr.status === 200) { try { var r = JSON.parse(xhr.responseText); if (r.result === 'success') document.getElementById('current-mode').textContent = mode === 'auto' ? '自动温控' : '手动控制'; } catch(e) {} } };
    xhr.send('mode=' + encodeURIComponent(mode) + '&fan_percent=' + encodeURIComponent(fanSpeed));
}

function togglePidPanel() {
    var c = document.getElementById('pid-content');
    var i = document.getElementById('pid-toggle-icon');
    if (c.classList.contains('active')) { c.classList.remove('active'); i.textContent = '\u25BC'; }
    else { c.classList.add('active'); i.textContent = '\u25B2'; }
}

function setPidParams() {
    var kp = document.getElementById('kp-input').value;
    var ki = document.getElementById('ki-input').value;
    var kd = document.getElementById('kd-input').value;
    var cycle = document.getElementById('cycle-input').value;
    if (!kp || !ki || !kd || !cycle) { alert('请填写所有PID参数'); return; }
    var xhr = new XMLHttpRequest();
    xhr.open('POST', '<%=url("admin/status/sensors/setpid")%>');
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
    xhr.onload = function() {
        if (xhr.status === 200) { try { var r = JSON.parse(xhr.responseText); alert(r.result === 'success' ? 'PID参数更新成功！' : '出错: ' + r.message); } catch(e) { alert('解析响应出错'); } }
        else { alert('请求失败'); }
    };
    xhr.send('kp=' + encodeURIComponent(kp) + '&ki=' + encodeURIComponent(ki) + '&kd=' + encodeURIComponent(kd) + '&cycle=' + encodeURIComponent(cycle));
}

function updateCards(data) {
    sensors.forEach(function(sensor) {
        var value = data[sensor.id] || 'N/A';
        var card = document.getElementById('card-' + sensor.id);
        if (!card) return;
        var valueEl = card.querySelector('.card-value');
        if (value !== 'N/A') {
            if (sensor.type === 'fan') {
                var fp = parseInt(value);
                valueEl.innerHTML = fp + '<span class="card-unit">%</span>';
                if (data.fan_mode !== 'manual') {
                    var s = document.getElementById('fan-slider');
                    var sv = document.getElementById('fan-slider-value');
                    if (s && sv) { s.value = fp; sv.textContent = fp + '%'; }
                }
                document.getElementById('current-mode').textContent = data.fan_mode === 'auto' ? '自动温控' : '手动控制';
                document.getElementById('current-temp').textContent = data.fan_target_temp || '55';
                document.querySelectorAll('.mode-btn').forEach(function(btn) { btn.classList.toggle('active', btn.dataset.mode === data.fan_mode); });
                var ti = document.getElementById('target-temp-input');
                if (ti && document.activeElement !== ti) ti.value = data.fan_target_temp || '55';
                var kpI = document.getElementById('kp-input');
                var kiI = document.getElementById('ki-input');
                var kdI = document.getElementById('kd-input');
                var cyI = document.getElementById('cycle-input');
                if (kpI && document.activeElement !== kpI) kpI.value = data.kp || '5.0';
                if (kiI && document.activeElement !== kiI) kiI.value = data.ki || '0.1';
                if (kdI && document.activeElement !== kdI) kdI.value = data.kd || '1.0';
                if (cyI && document.activeElement !== cyI) cyI.value = data.cycle || '10';
            } else {
                valueEl.innerHTML = value + '<span class="card-unit">' + sensor.unit + '</span>';
                if (sensor.type === 'temp') {
                    var t = parseInt(value);
                    if (!isNaN(t)) valueEl.className = 'card-value ' + (t < 50 ? 'temp-low' : t < 70 ? 'temp-medium' : 'temp-high');
                }
            }
            if (historyData[sensor.id].length >= 60) historyData[sensor.id].shift();
            historyData[sensor.id].push(value === 'N/A' ? 0 : parseInt(value));
            drawChart('chart-' + sensor.id, historyData[sensor.id],
                      sensor.id === 'fan_percent' ? 100 : 80,
                      sensor.id === 'fan_percent' ? 0 : 20);
        } else {
            valueEl.innerHTML = 'N/A';
            valueEl.className = 'card-value';
        }
    });
    lastUpdateEl.textContent = new Date().toTimeString().substring(0, 8);
}

function fetchSensorData() {
    var xhr = new XMLHttpRequest();
    xhr.open('GET', '<%=url("admin/status/sensors/data")%>');
    xhr.setRequestHeader('Cache-Control', 'no-cache');
    xhr.onload = function() {
        if (xhr.status === 200) { try { updateCards(JSON.parse(xhr.responseText)); } catch(e) { console.error(e); } }
    };
    xhr.send();
}

document.addEventListener('DOMContentLoaded', function() {
    initCards();
    fetchSensorData();
    setInterval(fetchSensorData, 1000);
});
</script>

<%+footer%>
INNER_EOF

# ==================== 创建风扇配置文件 ====================
echo "创建风扇配置文件..."
cat << 'INNER_EOF' > /etc/fan_config
# 风扇控制配置 - Cyber 3588 AIB
# 方案B: raw sysfs PWM 控制 (pwm_fan 内核模块已卸载)
mode=auto
target_temp=55
min_speed=20
max_speed=100

# PWM 参数 (sysfs duty_cycle 单位为纳秒)
pwm_period=50000

# PID参数设置
kp=5.0
ki=0.1
kd=1.0
cycle=10

# 风扇反转 (1=百分比越高转速越小, 0=正常)
fan_invert=1
INNER_EOF

# ==================== 创建开机启动服务 ====================
echo "创建开机启动服务..."
cat << 'INNER_EOF' > /etc/init.d/fancontrol
#!/bin/sh /etc/rc.common

START=99
STOP=10

PWM_CHIP="/sys/class/pwm/pwmchip0"
PWM_PATH="${PWM_CHIP}/pwm0"
PWM_PERIOD=50000

start() {
    echo "Starting fan control service (raw sysfs PWM)"

    # 卸载 pwm_fan 内核模块，释放 PWM 控制权
    rmmod pwm_fan 2>/dev/null
    sleep 1

    # 设置 raw sysfs PWM
    if [ ! -d "$PWM_PATH" ]; then
        echo 0 > "$PWM_CHIP/export"
        sleep 1
    fi

    if [ -d "$PWM_PATH" ]; then
        echo 0 > "$PWM_PATH/enable" 2>/dev/null
        echo $PWM_PERIOD > "$PWM_PATH/period"
        echo 0 > "$PWM_PATH/duty_cycle"
        echo normal > "$PWM_PATH/polarity"
        echo 1 > "$PWM_PATH/enable"
    else
        echo "ERROR: PWM path $PWM_PATH not available"
        return 1
    fi

    # 启动 PID 温控守护进程
    /usr/bin/fan_control >/tmp/fan_control.log 2>&1 &
}

stop() {
    echo "Stopping fan control service"
    # 兼容无 pkill 的系统：用 ps + kill 替代
    for pid in $(ps | grep "/usr/bin/fan_control" | grep -v grep | awk '{print $1}'); do
        kill $pid 2>/dev/null
    done

    # 禁用 PWM 输出 (风扇停转)
    if [ -d "$PWM_PATH" ]; then
        echo 0 > "$PWM_PATH/enable" 2>/dev/null
    fi
}

restart() {
    stop
    sleep 1
    start
}
INNER_EOF

# ==================== 设置权限 ====================
chmod +x /etc/init.d/fancontrol
chmod +x /usr/bin/fan_control
chmod +x /usr/bin/set_fan_speed
chmod +x /usr/bin/sensors_monitor

# ==================== 启用并启动服务 ====================
/etc/init.d/fancontrol enable
/etc/init.d/fancontrol start

# ==================== 清理 LuCI 缓存并重启服务 ====================
rm -rf /tmp/luci-*
/etc/init.d/rpcd restart
sleep 1
/etc/init.d/uhttpd restart

echo "=============================================="
echo " Cyber 3588 AIB 温度监控和风扇控制 V3.0"
echo "----------------------------------------------"
echo " 方案B: raw sysfs PWM 控制"
echo " PWM: pwmchip0/pwm0 (period=50000ns, normal polarity)"
echo " pwm_fan 内核模块已卸载，完全由脚本控制"
echo "----------------------------------------------"
echo " V3.0 修复内容:"
echo "  1. LuCI 菜单不显示 (ACL + acl_depends)"
echo "  2. CPU/WiFi/SSD/modem 温度读取"
echo "  3. modem_temp 带°C后缀导致PID报错"
echo "  4. init 脚本 stop() 兼容无 pkill"
echo "  5. 子路由添加 .leaf = true"
echo "  6. 风扇反转支持 (fan_invert=1)"
echo "----------------------------------------------"
echo " PID参数范围:"
echo "  Kp: 0.1-20.0 (推荐5.0)"
echo "  Ki: 0.01-5.0 (推荐0.1)"
echo "  Kd: 0-10.0 (推荐1.0)"
echo "  周期: 1-10秒 (推荐10)"
echo "----------------------------------------------"
echo " 注意: 清除浏览器缓存后刷新 LuCI 页面"
echo "       如果菜单仍不显示, 请退出重新登录"
echo "----------------------------------------------"
echo " 访问路径: LuCI -> 状态 -> 硬件监控"
echo "=============================================="

sync
echo "Done!"
