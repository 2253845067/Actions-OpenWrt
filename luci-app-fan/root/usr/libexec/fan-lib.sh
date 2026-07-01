#!/bin/sh
# Shared library for fan control utilities
# POSIX/ash compatible for OpenWrt
# This file should be sourced by fan-control and luci.fan

# Constants
FAN_LIB_SMART_MIN_MILLI=30000
FAN_LIB_SMART_MAX_MILLI=60000
FAN_LIB_SMART_MAX_RPM=3000
FAN_LIB_SMART_MAX_RPM_MIN=500
FAN_LIB_SMART_MAX_RPM_MAX=10000

# Check if value is a valid unsigned integer
is_uint() {
    case "$1" in
        ''|*[!0-9]*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# Read file content and trim whitespace
read_trimmed() {
    value=$(cat "$1" 2>/dev/null) || return 1
    printf '%s' "$value" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Read a number from file
read_number() {
    value=$(read_trimmed "$1") || return 1
    [ -n "$value" ] || return 1
    value=$(printf '%s\n' "$value" | sed -n 's/[^0-9]*\([0-9][0-9]*\).*/\1/p' | head -n1)
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

# Clamp value to range [minimum, maximum]
clamp_uint() {
    value=$1
    minimum=$2
    maximum=$3

    [ "$value" -lt "$minimum" ] && value=$minimum
    [ "$value" -gt "$maximum" ] && value=$maximum
    printf '%s\n' "$value"
}

# Convert percentage (0-100) to raw PWM value (0-255)
percent_to_raw() {
    awk -v value="$1" 'BEGIN {
        raw = int((value * 255 / 100) + 0.5)
        if (raw < 0)
            raw = 0
        else if (raw > 255)
            raw = 255
        printf "%d", raw
    }'
}

# Convert raw PWM value (0-255) to percentage (0-100)
pwm_to_percent() {
    awk -v raw="$1" 'BEGIN { printf "%d", int((raw * 100 / 255) + 0.5) }'
}

# Estimate RPM from raw PWM value
# Returns empty if raw is empty or invalid
estimate_rpm_from_raw() {
    local raw=$1
    local max_rpm=${2:-$FAN_LIB_SMART_MAX_RPM}
    
    # Return empty if raw is not a valid uint
    is_uint "$raw" || return 1
    
    awk -v raw="$raw" -v max_rpm="$max_rpm" 'BEGIN {
        if (raw > 255)
            raw = 255
        printf "%d", int((raw * max_rpm / 255) + 0.5)
    }'
}

# Clamp RPM value to maximum
clamp_rpm() {
    local value=$1
    local max_rpm=${2:-$FAN_LIB_SMART_MAX_RPM}

    is_uint "$value" || return 1
    [ "$value" -gt "$max_rpm" ] && value=$max_rpm
    printf '%s\n' "$value"
}

# Parse Celsius temperature to milli-Celsius
parse_celsius_to_milli() {
    awk -v value="$1" 'BEGIN {
        if (value == "" || (value + 0) != value)
            exit 1

        milli = int((value * 1000) + 0.5)
        if (milli < 0)
            exit 1

        printf "%d", milli
    }'
}

# Convert milli-Celsius to Celsius string
milli_to_celsius() {
    awk -v value="$1" 'BEGIN { printf "%.1f", value / 1000 }'
}

# Find RPM candidate file in a directory
# Looks for: fan*_input, fan*_speed, fan*_rpm, rpm
find_rpm_candidate_in_dir() {
    local base=$1
    local candidate=

    [ -n "$base" ] || return 1
    [ -d "$base" ] || return 1

    for candidate in "$base"/fan*_input "$base"/fan*_speed "$base"/fan*_rpm "$base"/rpm; do
        if [ -r "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

# Compute ratio for load calculation
compute_ratio() {
    awk -v current="$1" -v off="$2" -v next="$3" -v start="$4" 'BEGIN {
        ratio = 0

        if (current != "") {
            if (off != "" && next != "" && next > off)
                ratio = (current - off) / (next - off)
            else if (start != "" && start > 0)
                ratio = current / start
        }

        if (ratio < 0)
            ratio = 0
        else if (ratio > 1)
            ratio = 1

        printf "%.3f", ratio
    }'
}

# Calculate smart PWM raw value based on temperature
smart_pwm_raw() {
    local temp=$1
    local min_temp=${2:-$FAN_LIB_SMART_MIN_MILLI}
    local max_temp=${3:-$FAN_LIB_SMART_MAX_MILLI}

    awk -v temp="$temp" -v min_temp="$min_temp" -v max_temp="$max_temp" 'BEGIN {
        if (temp <= min_temp)
            raw = 0
        else if (temp >= max_temp)
            raw = 255
        else
            raw = int((((temp - min_temp) * 255) / (max_temp - min_temp)) + 0.5)

        if (raw < 0)
            raw = 0
        else if (raw > 255)
            raw = 255

        printf "%d", raw
    }'
}

# PID Controller
# Arguments:
#   $1 - current_temp_milli (current temperature in milli-Celsius)
#   $2 - setpoint_milli (target temperature in milli-Celsius)
#   $3 - kp (proportional gain)
#   $4 - ki (integral gain)
#   $5 - kd (derivative gain)
#   $6 - last_error (previous error, for derivative calculation)
#   $7 - integral_sum (accumulated integral)
#   $8 - prev_temp_milli (previous temperature, for derivative calculation)
# Returns: pwm_raw integral_sum new_error prev_temp_milli
pid_pwm_raw() {
    local current_temp=$1
    local setpoint=$2
    local kp=$3
    local ki=$4
    local kd=$5
    local last_error=$6
    local integral_sum=$7
    local prev_temp=$8

    awk -v current="$current_temp" -v setpoint="$setpoint" -v kp="$kp" -v ki="$ki" -v kd="$kd" -v last_error="$last_error" -v integral="$integral_sum" -v prev_temp="$prev_temp" 'BEGIN {
        # Calculate error
        error = current - setpoint
        
        # Calculate integral (accumulated error)
        integral = integral + error
        
        # Anti-windup: limit integral
        integral_max = 1000000
        integral_min = -1000000
        if (integral > integral_max)
            integral = integral_max
        else if (integral < integral_min)
            integral = integral_min
        
        # Calculate derivative (rate of change of temperature)
        derivative = 0
        if (prev_temp != "")
            derivative = current - prev_temp
        
        # Calculate PID output
        p_term = kp * error / 1000
        i_term = ki * integral / 1000000
        d_term = kd * derivative / 1000
        
        output = p_term + i_term + d_term
        
        # Convert to PWM (0-255)
        pwm_raw = int(output + 0.5)
        
        # Clamp PWM
        if (pwm_raw < 0)
            pwm_raw = 0
        else if (pwm_raw > 255)
            pwm_raw = 255
        
        printf "%d %d %d %d", pwm_raw, integral, error, current
    }'
}

# Adaptive PID Auto-Tuning
# Analyzes error history and adjusts kp/ki/kd in real-time.
# This function should be called every PID cycle; it keeps a rotating
# error buffer and periodically applies simple rule-based adaptation.
#
# Arguments:
#   $1 - current_error_milli (setpoint - current_temp)
#   $2 - base_kp  (UCI initial value, used as starting point)
#   $3 - base_ki
#   $4 - base_kd
#   $5 - state_file  (path to adaptation state file, e.g. /tmp/run/fanADAPT)
#
# Output: tuned_kp tuned_ki tuned_kd
tune_pid_params() {
    local error=$1
    local kp=$2
    local ki=$3
    local kd=$4
    local state_file=$5

    awk -v error="$error" -v kp="$kp" -v ki="$ki" -v kd="$kd" -v state="$state_file" '
    BEGIN {
        BUF_SIZE   = 20
        ADAPT_CYC  = 15
        KP_MIN = 10;   KP_MAX = 1000
        KI_MIN = 0;    KI_MAX = 500
        KD_MIN = 0;    KD_MAX = 500

        # Try to read existing state file
        tuned_kp = kp; tuned_ki = ki; tuned_kd = kd
        cycle    = 0
        saved_kp = 0; saved_ki = 0; saved_kd = 0

        if ((getline line1 < state) > 0) {
            split(line1, f1, " ")
            tuned_kp = f1[1] + 0
            tuned_ki = f1[2] + 0
            tuned_kd = f1[3] + 0
            cycle    = f1[4] + 0
            saved_kp = (f1[5] != "") ? f1[5] + 0 : 0
            saved_ki = (f1[6] != "") ? f1[6] + 0 : 0
            saved_kd = (f1[7] != "") ? f1[7] + 0 : 0
            # Reset to base params if UCI config was changed
            if (saved_kp != kp || saved_ki != ki || saved_kd != kd) {
                tuned_kp = kp
                tuned_ki = ki
                tuned_kd = kd
                cycle = 0
                for (i = 1; i <= BUF_SIZE; i++)
                    err_buf[i] = 0
            }
        }

        for (i = 1; i <= BUF_SIZE; i++)
            err_buf[i] = 0

        if ((getline line2 < state) > 0) {
            split(line2, f2, " ")
            for (i = 1; i <= BUF_SIZE && i <= length(f2); i++)
                err_buf[i] = f2[i] + 0
        }
        close(state)

        # Shift buffer left, append new error
        for (i = 2; i <= BUF_SIZE; i++)
            err_buf[i-1] = err_buf[i]
        err_buf[BUF_SIZE] = error

        # --- Analyse every ADAPT_CYC cycles ---
        if (cycle >= ADAPT_CYC) {
            crossings = 0;  prev_sign = 0;  max_abs = 0
            sum_abs   = 0;  all_same   = 1;  first_sign = 0

            for (i = 1; i <= BUF_SIZE; i++) {
        printf "%d", err_buf[i] > state
        if (i < BUF_SIZE) printf " " > state
        }
        printf "\n" > state
                e = err_buf[i]
                abs_e = (e < 0) ? -e : e
                sum_abs += abs_e
                if (abs_e > max_abs) max_abs = abs_e

                s = (e > 0) ? 1 : ((e < 0) ? -1 : 0)
                if (i == 1) first_sign = s
                if (s != first_sign) all_same = 0
                if (prev_sign != 0 && s != 0 && s != prev_sign)
                    crossings++
                if (s != 0) prev_sign = s
            }
            mean = sum_abs / BUF_SIZE

            # Rule 1 — strong oscillation (many crossings + large amplitude)
            if (crossings >= 6 && max_abs > 2000) {
                tuned_kp = int(tuned_kp * 0.88)
                tuned_kd = int(tuned_kd * 1.08)
            }
            # Rule 2 — mild oscillation
            else if (crossings >= 6 && max_abs > 500) {
                tuned_kp = int(tuned_kp * 0.95)
            }
            # Rule 3 — slow / stuck response (all errors same sign)
            else if (all_same && mean > 3000) {
                tuned_kp = int(tuned_kp * 1.12)
                if (mean > 5000)
                    tuned_ki = int(tuned_ki * 1.15)
            }
            # Rule 4 — moderate steady-state offset
            else if (crossings <= 2 && mean > 1000) {
                tuned_kp = int(tuned_kp * 1.05)
                tuned_ki = int(tuned_ki * 1.08)
            }

            # Clamp
            if (tuned_kp < KP_MIN) tuned_kp = KP_MIN
            if (tuned_kp > KP_MAX) tuned_kp = KP_MAX
            if (tuned_ki < KI_MIN) tuned_ki = KI_MIN
            if (tuned_ki > KI_MAX) tuned_ki = KI_MAX
            if (tuned_kd < KD_MIN) tuned_kd = KD_MIN
            if (tuned_kd > KD_MAX) tuned_kd = KD_MAX

            cycle = 0
        }

        cycle++

        # Persist state (includes base kp/ki/kd for change detection)
        printf "%d %d %d %d %d %d %d\n", tuned_kp, tuned_ki, tuned_kd, cycle, kp, ki, kd > state
        for (i = 1; i <= BUF_SIZE; i++) {
        printf "%d", err_buf[i] > state
        if (i < BUF_SIZE) printf " " > state
        }
        printf "\n" > state
        printf "\n" > state
        close(state)

        # Return tuned parameters
        printf "%d %d %d", tuned_kp, tuned_ki, tuned_kd
    }'
}

# Combined adaptive PID: auto-tune + PID calculation in one awk call.
# Merges tune_pid_params + pid_pwm_raw to halve process spawns.
#
# Arguments:
#   $1 - temp_milli
#   $2 - setpoint_milli
#   $3 - base_kp       (UCI initial)
#   $4 - base_ki
#   $5 - base_kd
#   $6 - last_error
#   $7 - integral_sum
#   $8 - prev_temp
#   $9 - state_file    (adaptation state, e.g. /tmp/run/fanADAPT)
#
# Output: pwm_raw tuned_kp tuned_ki tuned_kd integral_sum error prev_temp

adaptive_pid_cycle() {
    local temp=$1
    local setpoint=$2
    local kp=$3
    local ki=$4
    local kd=$5
    local last_err=$6
    local integral=$7
    local prev_t=$8
    local state_file=$9

    awk -v temp="$temp" -v setpoint="$setpoint" \
        -v kp="$kp" -v ki="$ki" -v kd="$kd" \
        -v last_err="$last_err" -v integral="$integral" -v prev_t="$prev_t" \
        -v state="$state_file" '
    BEGIN {
        BUF_SIZE   = 20
        ADAPT_CYC  = 15
        KP_MIN = 10;   KP_MAX = 1000
        KI_MIN = 0;    KI_MAX = 500
        KD_MIN = 0;    KD_MAX = 500

        # Load adaptation state
        tuned_kp = kp; tuned_ki = ki; tuned_kd = kd
        cycle    = 0
        saved_kp = 0; saved_ki = 0; saved_kd = 0

        if ((getline line1 < state) > 0) {
            split(line1, f1, " ")
            tuned_kp = f1[1] + 0
            tuned_ki = f1[2] + 0
            tuned_kd = f1[3] + 0
            cycle    = f1[4] + 0
            saved_kp = (f1[5] != "") ? f1[5] + 0 : 0
            saved_ki = (f1[6] != "") ? f1[6] + 0 : 0
            saved_kd = (f1[7] != "") ? f1[7] + 0 : 0

            if (saved_kp != kp || saved_ki != ki || saved_kd != kd) {
                tuned_kp = kp
                tuned_ki = ki
                tuned_kd = kd
                cycle = 0
                for (i = 1; i <= BUF_SIZE; i++)
                    err_buf[i] = 0
            }
        }

        for (i = 1; i <= BUF_SIZE; i++)
            err_buf[i] = 0

        if ((getline line2 < state) > 0) {
            split(line2, f2, " ")
            for (i = 1; i <= BUF_SIZE && i <= length(f2); i++)
                err_buf[i] = f2[i] + 0
        }
        close(state)

        # Current error
        error = temp - setpoint

        # Push error into rotating buffer
        for (i = 2; i <= BUF_SIZE; i++)
            err_buf[i-1] = err_buf[i]
        err_buf[BUF_SIZE] = error

        # Analyse every ADAPT_CYC cycles
        if (cycle >= ADAPT_CYC) {
            crossings = 0;  prev_sign = 0;  max_abs = 0
            sum_abs   = 0;  all_same   = 1;  first_sign = 0

            for (i = 1; i <= BUF_SIZE; i++) {
                e = err_buf[i]
                abs_e = (e < 0) ? -e : e
                sum_abs += abs_e
                if (abs_e > max_abs) max_abs = abs_e

                s = (e > 0) ? 1 : ((e < 0) ? -1 : 0)
                if (i == 1) first_sign = s
                if (s != first_sign) all_same = 0
                if (prev_sign != 0 && s != 0 && s != prev_sign)
                    crossings++
                if (s != 0) prev_sign = s
            }
            mean = sum_abs / BUF_SIZE

            if (crossings >= 6 && max_abs > 2000) {
                tuned_kp = int(tuned_kp * 0.88)
                tuned_kd = int(tuned_kd * 1.08)
            } else if (crossings >= 6 && max_abs > 500) {
                tuned_kp = int(tuned_kp * 0.95)
            } else if (all_same && mean > 3000) {
                tuned_kp = int(tuned_kp * 1.12)
                if (mean > 5000)
                    tuned_ki = int(tuned_ki * 1.15)
            } else if (crossings <= 2 && mean > 1000) {
                tuned_kp = int(tuned_kp * 1.05)
                tuned_ki = int(tuned_ki * 1.08)
            }

            if (tuned_kp < KP_MIN) tuned_kp = KP_MIN
            if (tuned_kp > KP_MAX) tuned_kp = KP_MAX
            if (tuned_ki < KI_MIN) tuned_ki = KI_MIN
            if (tuned_ki > KI_MAX) tuned_ki = KI_MAX
            if (tuned_kd < KD_MIN) tuned_kd = KD_MIN
            if (tuned_kd > KD_MAX) tuned_kd = KD_MAX

            cycle = 0
        }
        cycle++

        # Persist adaptation state
        printf "%d %d %d %d %d %d %d\n", tuned_kp, tuned_ki, tuned_kd, cycle, kp, ki, kd > state
        for (i = 1; i <= BUF_SIZE; i++) {
            printf "%d", err_buf[i] > state
            if (i < BUF_SIZE) printf " " > state
        }
        printf "\n" > state
        close(state)

        # PID calculation with tuned params
        integral = integral + error
        integral_max = 1000000; integral_min = -1000000
        if (integral > integral_max) integral = integral_max
        else if (integral < integral_min) integral = integral_min

        derivative = 0
        if (prev_t != "")
            derivative = temp - prev_t

        p_term = tuned_kp * error / 1000
        i_term = tuned_ki * integral / 1000000
        d_term = tuned_kd * derivative / 1000
        output = p_term + i_term + d_term
        pwm_raw = int(output + 0.5)
        if (pwm_raw < 0)  pwm_raw = 0
        if (pwm_raw > 255) pwm_raw = 255

        # Return: pwm_raw tuned_kp tuned_ki tuned_kd integral error prev_temp
        printf "%d %d %d %d %d %d %d", pwm_raw, tuned_kp, tuned_ki, tuned_kd, integral, error, temp
    }'
}
# Check for fan stall: RPM sensor reads 0 while PWM duty is positive.
# Logs a warning to stderr if stall is detected; rate-limited (once per 5 min).
# Prerequisite: PWM_RPM_PATH and PWM_PATH must be set (caller ensures this).
FAN_STALL_LAST_LOG=0
check_fan_stall() {
    local rpm
    local now

    [ -n "$PWM_RPM_PATH" ] || return 0

    rpm=$(read_number "$PWM_RPM_PATH" 2>/dev/null) || return 0

    if [ "$rpm" -eq 0 ]; then
        now=$(date +%s 2>/dev/null) || now=0
        if [ "$now" -gt 0 ] && [ $(( now - FAN_STALL_LAST_LOG )) -ge 300 ]; then
            FAN_STALL_LAST_LOG=$now
            echo "WARN: Fan stall detected — PWM active but RPM sensor reports 0 (hwmon: ${PWM_RPM_PATH})" >&2
            logger -t luci-fan -p daemon.warn "Fan stall detected — PWM active but RPM=0"
        fi
    fi
}

# Resolve PWM hwmon path and find associated RPM path
# Sets: PWM_HWMON, PWM_NAME, PWM_PATH, PWM_ENABLE_PATH, PWM_RPM_PATH
resolve_pwm_hwmon() {
    local base_dir="${1:-}"
    local hwmon entry preferred fallback name
    local pwm_device pwm_parent candidate fallback_hwmon hwmon_device

    [ -d "${base_dir}/sys/class/hwmon" ] || return 1

    for hwmon in "${base_dir}"/sys/class/hwmon/hwmon*; do
        if [ -d "$hwmon" ]; then
            if [ -w "$hwmon/pwm1" ]; then
                name=$(read_trimmed "$hwmon/name") || name=''
                entry="$hwmon|$name"

                case "$name" in
                    pwmfan|pwm-fan|pwm_fan)
                        preferred=$entry
                        break
                        ;;
                    *)
                        [ -z "$fallback" ] && fallback=$entry
                        ;;
                esac
            fi
        fi
    done

    entry=${preferred:-$fallback}
    [ -n "$entry" ] || return 1

    PWM_HWMON=${entry%%|*}
    PWM_NAME=${entry#*|}
    PWM_PATH="$PWM_HWMON/pwm1"
    PWM_ENABLE_PATH=''
    PWM_RPM_PATH=''

    if [ -w "$PWM_HWMON/pwm1_enable" ]; then
        PWM_ENABLE_PATH="$PWM_HWMON/pwm1_enable"
    fi

    # Try to find RPM path in the same hwmon
    candidate=$(find_rpm_candidate_in_dir "$PWM_HWMON") || candidate=''
    if [ -n "$candidate" ]; then
        PWM_RPM_PATH="$candidate"
        return 0
    fi

    # Try device directory
    pwm_device=$(readlink -f "$PWM_HWMON/device" 2>/dev/null) || pwm_device=''
    pwm_parent=$(dirname "$pwm_device" 2>/dev/null)

    for hwmon in "$pwm_device" "$pwm_device"/hwmon/hwmon* "$pwm_parent"/hwmon/hwmon*; do
        candidate=$(find_rpm_candidate_in_dir "$hwmon") || candidate=''
        if [ -n "$candidate" ]; then
            PWM_RPM_PATH="$candidate"
            return 0
        fi
    done

    # Search all hwmon devices for a related one
    for hwmon in "${base_dir}"/sys/class/hwmon/hwmon*; do
        if [ -d "$hwmon" ]; then
            if [ "$hwmon" != "$PWM_HWMON" ]; then
                candidate=$(find_rpm_candidate_in_dir "$hwmon") || candidate=''
                if [ -n "$candidate" ]; then
                    hwmon_device=$(readlink -f "$hwmon/device" 2>/dev/null) || hwmon_device=''

                    if [ -n "$pwm_device" ] && [ -n "$hwmon_device" ]; then
                        case "$hwmon_device" in
                            "$pwm_device"|"$pwm_device"/*)
                                PWM_RPM_PATH="$candidate"
                                return 0
                                ;;
                        esac

                        case "$pwm_device" in
                            "$hwmon_device"|"$hwmon_device"/*)
                                PWM_RPM_PATH="$candidate"
                                return 0
                                ;;
                        esac
                    fi

                    [ -z "$fallback_hwmon" ] && fallback_hwmon=$candidate
                fi
            fi
        fi
    done

    [ -n "$fallback_hwmon" ] || return 1
    PWM_RPM_PATH="$fallback_hwmon"
    return 0
}

# Read PWM runtime values
# Sets: PWM_RAW, PWM_ENABLE, PWM_RPM, PWM_PERCENT
# Returns 0 on success, 1 if PWM path is not readable
read_pwm_runtime() {
    PWM_RAW=$(read_number "$PWM_PATH") || PWM_RAW=''
    PWM_ENABLE=''
    PWM_RPM=''
    PWM_PERCENT=''

    if [ -n "$PWM_ENABLE_PATH" ]; then
        PWM_ENABLE=$(read_trimmed "$PWM_ENABLE_PATH") || PWM_ENABLE=''
    fi

    if [ -n "$PWM_RPM_PATH" ]; then
        PWM_RPM=$(read_number "$PWM_RPM_PATH") || PWM_RPM=''
    fi

    if [ -n "$PWM_RAW" ]; then
        PWM_PERCENT=$(pwm_to_percent "$PWM_RAW") || PWM_PERCENT=''
    fi
    
    # Return success only if we could read PWM_RAW
    if [ -n "$PWM_RAW" ]; then
        return 0
    else
        return 1
    fi
}

# Read mode from UCI config
# Returns: turbo, smart, manual, or pid (defaults to smart)
read_mode() {
    local value

    value=$(uci -q get 'luci-fan.@luci-fan[0].mode' 2>/dev/null)

    case "$value" in
        turbo|smart|manual|pid)
            printf '%s\n' "$value"
            ;;
        *)
            printf '%s\n' 'smart'
            ;;
    esac
}

# Read unsigned integer from UCI config
read_uci_uint() {
    local value

    value=$(uci -q get "luci-fan.@luci-fan[0].$1" 2>/dev/null)
    is_uint "$value" || return 1
    printf '%s\n' "$value"
}

# Read temperature (float) from UCI and convert to milli-Celsius
read_uci_temp_milli() {
    local value

    value=$(uci -q get "luci-fan.@luci-fan[0].$1" 2>/dev/null)
    [ -n "$value" ] || return 1
    parse_celsius_to_milli "$value"
}

# Resolve smart temperature window from UCI
# Sets: SMART_WINDOW_ON_MILLI, SMART_WINDOW_OFF_MILLI
resolve_smart_window_milli() {
    local on_milli off_milli

    on_milli=$(read_uci_temp_milli on_temp) || on_milli=$FAN_LIB_SMART_MAX_MILLI
    off_milli=$(read_uci_temp_milli off_temp) || off_milli=$FAN_LIB_SMART_MIN_MILLI

    on_milli=$(clamp_uint "$on_milli" 100 150000)
    off_milli=$(clamp_uint "$off_milli" 0 149900)

    if [ "$on_milli" -le "$off_milli" ]; then
        if [ "$off_milli" -ge 149900 ]; then
            off_milli=149800
            on_milli=149900
        else
            on_milli=$((off_milli + 100))
        fi
    fi

    SMART_WINDOW_ON_MILLI=$on_milli
    SMART_WINDOW_OFF_MILLI=$off_milli
}

# Resolve max RPM from UCI
# Sets: EFFECTIVE_MAX_RPM
resolve_max_rpm() {
    local max_rpm

    max_rpm=$(read_uci_uint max_rpm) || max_rpm=$FAN_LIB_SMART_MAX_RPM
    max_rpm=$(clamp_uint "$max_rpm" "$FAN_LIB_SMART_MAX_RPM_MIN" "$FAN_LIB_SMART_MAX_RPM_MAX")
    EFFECTIVE_MAX_RPM=$max_rpm
}

# Resolve primary thermal zone
# Sets: PRIMARY_ZONE, PRIMARY_THERMAL_TYPE
resolve_primary_thermal_zone() {
    local base_dir="${1:-}"
    local zone_path thermal_zone thermal_type fallback_zone fallback_type

    if [ -n "$ZONE" ]; then
        zone_path="${base_dir}/sys/class/thermal/$ZONE"
        if [ -r "$zone_path/temp" ]; then
            PRIMARY_ZONE=$ZONE
            PRIMARY_THERMAL_TYPE=$(read_trimmed "$zone_path/type") || PRIMARY_THERMAL_TYPE=''
            return 0
        fi
    fi

    for thermal_zone in "${base_dir}"/sys/class/thermal/thermal_zone*; do
        if [ -d "$thermal_zone" ]; then
            if [ -r "$thermal_zone/temp" ]; then
                thermal_type=$(read_trimmed "$thermal_zone/type") || thermal_type=''

                case "$thermal_type" in
                    *cpu*|*soc*|*package*)
                        PRIMARY_ZONE=${thermal_zone##*/}
                        PRIMARY_THERMAL_TYPE=$thermal_type
                        return 0
                        ;;
                    *)
                        if [ -z "$fallback_zone" ]; then
                            fallback_zone=${thermal_zone##*/}
                            fallback_type=$thermal_type
                        fi
                        ;;
                esac
            fi
        fi
    done

    [ -n "$fallback_zone" ] || return 1
    PRIMARY_ZONE=$fallback_zone
    PRIMARY_THERMAL_TYPE=$fallback_type
    return 0
}

# Load board profile info
# Sets: BOARD_NAME, MODEL_NAME, IS_AIB, PROFILE
load_board_profile() {
    local sysinfo_dir="${1:-${SYSINFO_DIR:-/tmp/sysinfo}}"
    local lowered

    BOARD_NAME=$(read_trimmed "$sysinfo_dir/board_name") || BOARD_NAME=''
    MODEL_NAME=$(read_trimmed "$sysinfo_dir/model") || MODEL_NAME=''
    lowered=$(printf '%s %s\n' "$BOARD_NAME" "$MODEL_NAME" | tr '[:upper:]' '[:lower:]')

    if printf '%s\n' "$lowered" | grep -Eiq 'cyber.*3588.*aib|rk3588.*aib'; then
        IS_AIB=1
        PROFILE='cyber3588-aib'
    else
        IS_AIB=0
        PROFILE='generic'
    fi
}

# Get fan trip point from kernel
# Usage: get_fan_tp
# Output: zone trip_point current_temp [max_temp]
get_fan_tp() {
    local zone cdev trip temp mintemp mintrip minzone maxtemp
    local base_path='/sys/class/thermal'

    [ -d "$base_path" ] || return 1

    for zone in "$base_path"/thermal_zone*; do
        [ -d "$zone" ] || continue

        for cdev in "$zone"/cdev[0-9]*; do
            case "${cdev##*/}" in
                cdev[0-9]*) ;;
                *) continue ;;
            esac

            [ -d "$cdev" ] || continue

            if grep -Fiq fan "$cdev/type" 2>/dev/null; then
                trip=$(cat "${cdev}_trip_point" 2>/dev/null) || continue
                if grep -Fwq active "${zone}/trip_point_${trip}_type" 2>/dev/null; then
                    if [ -w "${zone}/trip_point_${trip}_temp" ]; then
                        if [ -w "${zone}/trip_point_${trip}_hyst" ]; then
                            temp=$(cat "${zone}/trip_point_${trip}_temp" 2>/dev/null) || continue
                            zone_name=${zone##*/}

                            if [ -z "$mintemp" ] || [ "$temp" -lt "$mintemp" ]; then
                                if [ -n "$mintemp" ]; then
                                    if [ "$zone_name" = "$minzone" ]; then
                                        maxtemp=$mintemp
                                    else
                                        maxtemp=
                                    fi
                                fi

                                mintemp=$temp
                                mintrip=$trip
                                minzone=$zone_name
                            elif [ -z "$maxtemp" ] || [ "$temp" -lt "$maxtemp" ]; then
                                maxtemp=$temp
                            fi
                        fi
                    fi
                fi
            fi
        done
    done

    if [ -n "$mintemp" ]; then
        echo "$minzone" "$mintrip" "$mintemp" "$maxtemp"
        return 0
    fi

    return 1
}
