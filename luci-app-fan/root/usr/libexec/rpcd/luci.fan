#!/bin/sh

# Source jshn.sh with fallback path
if [ -f /usr/share/libubox/jshn.sh ]; then
	. /usr/share/libubox/jshn.sh
elif [ -n "${IPKG_INSTROOT}" ] && [ -f "${IPKG_INSTROOT}/usr/share/libubox/jshn.sh" ]; then
	. "${IPKG_INSTROOT}/usr/share/libubox/jshn.sh"
fi

# Source fan-lib.sh with fallback path
if [ -f /usr/libexec/fan-lib.sh ]; then
	. /usr/libexec/fan-lib.sh
elif [ -n "${IPKG_INSTROOT}" ] && [ -f "${IPKG_INSTROOT}/usr/libexec/fan-lib.sh" ]; then
	. "${IPKG_INSTROOT}/usr/libexec/fan-lib.sh"
fi

FAN_CONTROL="/usr/libexec/fan-control"
[ -x "$FAN_CONTROL" ] || FAN_CONTROL="${IPKG_INSTROOT}/usr/libexec/fan-control"
SYSINFO_DIR="/tmp/sysinfo"

# Wrapper for reading UCI uint values
get_uci_temp() {
	local value

	value=$(uci -q get "luci-fan.@luci-fan[0].$1" 2>/dev/null)
	is_uint "$value" || return 1
	printf '%s\n' "$value"
}

# Read PID parameters
read_pid_params() {
	local kp ki kd setpoint

	kp=$(read_uci_uint pid_kp) || kp=200
	ki=$(read_uci_uint pid_ki) || ki=50
	kd=$(read_uci_uint pid_kd) || kd=100
	setpoint=$(read_uci_temp_milli pid_setpoint) || setpoint=60000

	# Clamp values
	kp=$(clamp_uint "$kp" 0 1000)
	ki=$(clamp_uint "$ki" 0 500)
	kd=$(clamp_uint "$kd" 0 500)
	setpoint=$(clamp_uint "$setpoint" 30000 100000)

	json_add_int pid_kp "$kp"
	json_add_int pid_ki "$ki"
	json_add_int pid_kd "$kd"
	if [ -n "$setpoint" ]; then
		json_add_string pid_setpoint "$(milli_to_celsius "$setpoint")"
	else
		json_add_string pid_setpoint ""
	fi
}

# Read adaptive PID tuning state from cache
read_adapt_state() {
	local adapt_file="/tmp/run/fanADAPT"
	local tuned_kp tuned_ki tuned_kd

	if [ -s "$adapt_file" ]; then
		set -- $(head -n1 "$adapt_file" 2>/dev/null)
		tuned_kp=$1
		tuned_ki=$2
		tuned_kd=$3
		if is_uint "$tuned_kp" && is_uint "$tuned_ki" && is_uint "$tuned_kd"; then
			json_add_boolean pid_adaptive 1
			json_add_int pid_tuned_kp "$tuned_kp"
			json_add_int pid_tuned_ki "$tuned_ki"
			json_add_int pid_tuned_kd "$tuned_kd"
			return 0
		fi
	fi

	json_add_boolean pid_adaptive 0
	json_add_int pid_tuned_kp 0
	json_add_int pid_tuned_ki 0
	json_add_int pid_tuned_kd 0
}

resolve_zone_trip() {
	set -- $($FAN_CONTROL get 2>/dev/null)
	if [ -n "$1" ] && [ -n "$2" ]; then
		ZONE=$1
		TRIP=$2
		return 0
	fi
	return 1
}

json_add_common() {
	json_add_string board_name "$BOARD_NAME"
	json_add_string model_name "$MODEL_NAME"
	json_add_boolean is_aib "$IS_AIB"
	json_add_string profile "$PROFILE"
	json_add_boolean enabled "$ENABLED"
	json_add_string mode "$MODE"
	json_add_int manual_pwm "$MANUAL_PWM"
	json_add_int poll_interval "$POLL_INTERVAL"
}

# Safe json helper: only add non-empty values
json_add_string_if_not_empty() {
	local key=$1
	local value=$2
	if [ -n "$value" ]; then
		json_add_string "$key" "$value"
	else
		json_add_string "$key" ""
	fi
}

json_add_empty_runtime() {
	json_add_string zone ""
	json_add_string thermal_type ""
	json_add_string zone_temp ""
	json_add_string fan_on_temp ""
	json_add_string fan_off_temp ""
	json_add_string configured_on_temp ""
	json_add_string configured_off_temp ""
	json_add_string hysteresis ""
	json_add_string next_trip_temp ""
	json_add_string headroom ""
	json_add_string start_delta ""
	json_add_string load_ratio "0"
	json_add_string state "disabled"
	json_add_boolean thermal_supported 0
	json_add_boolean pwm_supported 0
	json_add_boolean mode_supported 0
	json_add_string hwmon_name ""
	json_add_string hwmon_path ""
	json_add_string pwm_raw ""
	json_add_string pwm_percent ""
	json_add_string pwm_enable_mode ""
	json_add_string fan_rpm ""
	json_add_string actual_fan_rpm ""
	json_add_string estimated_fan_rpm ""
	json_add_string rpm_source "unavailable"
	json_add_int fan_max_rpm "$FAN_LIB_SMART_MAX_RPM"
	json_add_string smart_min_temp ""
	json_add_string smart_max_temp ""
}

# Collect all available thermal zones
collect_all_thermal_zones() {
	json_add_array thermal_zones

	if [ -n "$ZONE" ]; then
		local zone_path="/sys/class/thermal/$ZONE"
		local temp=$(read_number "$zone_path/temp") || temp=""

		json_add_object
		json_add_string name "$ZONE"
		json_add_string type "$thermal_type"
		if [ -n "$temp" ]; then
			json_add_string temp "$(milli_to_celsius "$temp")"
		else
			json_add_string temp ""
		fi
		json_close_object
	fi

	json_close_array
}

# Collect all available hwmon sensors
collect_all_hwmon_sensors() {
	local hwmon name file label temp fan_input hwmon_name

	json_add_array hwmon_sensors

	for hwmon in /sys/class/hwmon/hwmon*; do
		if [ -d "$hwmon" ]; then
			name=$(read_trimmed "$hwmon/name") || name=""
			hwmon_name=${hwmon##*/}

			json_add_object
			json_add_string name "$hwmon_name"
			if [ -n "$name" ]; then
				json_add_string device_name "$name"
			else
				json_add_string device_name ""
			fi

			# Look for temperature inputs
			json_add_array temps
			for file in "${hwmon}/temp"*_input; do
				if [ -r "$file" ]; then
					label=""
					if [ -r "${file%_input}_label" ]; then
						label=$(read_trimmed "${file%_input}_label")
					fi
					temp=$(read_number "$file") || temp=""
					
					if [ -n "$temp" ]; then
						json_add_object
						json_add_string file "${file##*/}"
					if [ -n "$label" ]; then
						json_add_string label "$label"
					else
						json_add_string label ""
					fi
					json_add_string temp "$(milli_to_celsius "$temp")"
				pct_val=$(awk -v t="$temp" 'BEGIN {p=t/100000; if(p>1)p=1; printf "%.4f", p}' 2>/dev/null)
				[ -n "$pct_val" ] && json_add_string percent "$pct_val"
						json_close_object
					fi
				fi
			done
			json_close_array

			# Look for fan inputs
			json_add_array fans
			for file in "${hwmon}/fan"*_input; do
				if [ -r "$file" ]; then
					label=""
					if [ -r "${file%_input}_label" ]; then
						label=$(read_trimmed "${file%_input}_label")
					fi
					fan_input=$(read_number "$file") || fan_input=""
					
					json_add_object
					json_add_string file "${file##*/}"
					if [ -n "$label" ]; then
						json_add_string label "$label"
					else
						json_add_string label ""
					fi
					if [ -n "$fan_input" ]; then
						json_add_int rpm "$fan_input"
					else
						json_add_string rpm ""
					fi
					json_close_object
				fi
			done
			json_close_array

			json_close_object
		fi
	done

	json_close_array
}

get_status() {
	local zone_path primary_zone_path
	local fan_on_temp zone_temp fan_off_temp next_trip_temp thermal_type headroom start_delta load_ratio
	local configured_on_milli configured_off_milli configured_max_rpm state
	local thermal_supported pwm_supported mode_supported runtime_error supported trip_point_value trip_supported
	local actual_fan_rpm estimated_fan_rpm display_fan_rpm rpm_source target_raw

	load_board_profile "$SYSINFO_DIR"
	ENABLED=$(uci -q get luci-fan.@luci-fan[0].enabled 2>/dev/null)
	if [ "$ENABLED" != '1' ]; then
		ENABLED=0
	fi
	MODE=$(read_mode)
	MANUAL_PWM=$(get_uci_temp manual_pwm) || MANUAL_PWM=70
	POLL_INTERVAL=$(get_uci_temp poll_interval) || POLL_INTERVAL=5
	trip_point_value=0
	thermal_supported=0
	trip_supported=0
	pwm_supported=0
	runtime_error=''

	json_init
	json_add_common

	if resolve_primary_thermal_zone ""; then
		thermal_supported=1
		primary_zone_path="/sys/class/thermal/$PRIMARY_ZONE"
		ZONE=$PRIMARY_ZONE
		zone_temp=$(read_number "$primary_zone_path/temp") || zone_temp=''
		thermal_type=$PRIMARY_THERMAL_TYPE
	else
		zone_temp=''
		thermal_type=''
	fi

	if [ -x "$FAN_CONTROL" ] && resolve_zone_trip; then
		trip_supported=1
		trip_point_value=$TRIP
	fi

	if [ "$thermal_supported" != '1' ] && [ -n "$ZONE" ]; then
		zone_path="/sys/class/thermal/$ZONE"
		if [ -r "$zone_path/temp" ]; then
			thermal_supported=1
			zone_temp=$(read_number "$zone_path/temp") || zone_temp=''
			thermal_type=$(read_trimmed "$zone_path/type") || thermal_type=''
		fi
	fi

	resolve_smart_window_milli
	resolve_max_rpm
	configured_on_milli=$SMART_WINDOW_ON_MILLI
	configured_off_milli=$SMART_WINDOW_OFF_MILLI
	configured_max_rpm=$EFFECTIVE_MAX_RPM
	fan_off_temp=$configured_off_milli
	fan_on_temp=$configured_on_milli
	next_trip_temp=$configured_on_milli

	if resolve_pwm_hwmon ""; then
		read_pwm_runtime 2>/dev/null || true
		pwm_supported=1
	fi

	mode_supported=0
	case "$MODE" in
		smart)
			if { [ "$thermal_supported" = '1' ] && [ "$pwm_supported" = '1' ]; } || [ "$trip_supported" = '1' ]; then
				mode_supported=1
			fi
			;;
		*)
			if [ "$pwm_supported" = '1' ]; then
				mode_supported=1
			fi
			;;
	esac

	actual_fan_rpm=''
	estimated_fan_rpm=''
	display_fan_rpm=''
	rpm_source='unavailable'

	if [ "$pwm_supported" = '1' ]; then
		# Try to get actual RPM from hardware sensor
		if is_uint "$PWM_RPM"; then
			actual_fan_rpm=$(clamp_rpm "$PWM_RPM" "$configured_max_rpm")
			display_fan_rpm=$actual_fan_rpm
			rpm_source='actual'
		fi

		# Try to estimate RPM from current PWM_RAW
		if is_uint "$PWM_RAW"; then
			estimated_fan_rpm=$(estimate_rpm_from_raw "$PWM_RAW" "$configured_max_rpm")
		fi

		# If we couldn't read PWM_RAW but the service is enabled, estimate from target
		if [ -z "$estimated_fan_rpm" ] && [ "$ENABLED" = '1' ]; then
			case "$MODE" in
				turbo)
					target_raw=255
					;;
				manual)
					target_raw=$(percent_to_raw "$MANUAL_PWM")
					;;
				pid)
					# PID mode: use current PWM_RAW directly
					# If PWM_RAW is not available, estimate from zone_temp and setpoint
					if is_uint "$PWM_RAW"; then
						target_raw="$PWM_RAW"
					elif [ -n "$zone_temp" ]; then
						# Estimate PWM based on temperature relative to setpoint
						local setpoint_milli=$(read_uci_temp_milli pid_setpoint) || setpoint_milli=60000
						if [ "$zone_temp" -gt "$setpoint_milli" ]; then
							local diff=$((zone_temp - setpoint_milli))
							# Increase PWM above setpoint
							target_raw=$((150 + (diff / 1000 * 10)))
							[ "$target_raw" -gt 255 ] && target_raw=255
						else
							local diff=$((setpoint_milli - zone_temp))
							# Decrease PWM below setpoint
							target_raw=$((150 - (diff / 1000 * 10)))
							[ "$target_raw" -lt 0 ] && target_raw=0
						fi
					else
						target_raw=150
					fi
					;;
				*)
					if [ -n "$zone_temp" ]; then
						target_raw=$(smart_pwm_raw "$zone_temp" "$configured_off_milli" "$configured_on_milli")
					fi
					;;
			esac

			if is_uint "$target_raw"; then
				estimated_fan_rpm=$(estimate_rpm_from_raw "$target_raw" "$configured_max_rpm")
			fi
		fi

		# Clamp estimated RPM if valid
		if is_uint "$estimated_fan_rpm"; then
			estimated_fan_rpm=$(clamp_rpm "$estimated_fan_rpm" "$configured_max_rpm")
		fi

		# Fall back to estimated if no actual reading
		if [ -z "$display_fan_rpm" ] && is_uint "$estimated_fan_rpm"; then
			display_fan_rpm=$estimated_fan_rpm
			rpm_source='estimated'
		fi
	fi

	state='disabled'
	if [ "$ENABLED" = '1' ]; then
		if [ "$pwm_supported" = '1' ] && [ -n "$PWM_RAW" ]; then
			if [ "$PWM_RAW" -ge 200 ]; then
				state='active'
			elif [ "$PWM_RAW" -gt 0 ]; then
				state='transition'
			else
				state='standby'
			fi
		elif [ -n "$zone_temp" ] && [ "$zone_temp" -ge "$configured_on_milli" ]; then
			state='active'
		elif [ -n "$zone_temp" ] && [ "$zone_temp" -gt "$configured_off_milli" ]; then
			state='transition'
		else
			state='standby'
		fi
	fi

	headroom=''
	if [ -n "$zone_temp" ]; then
		headroom=$((configured_on_milli - zone_temp))
	fi
	start_delta=''
	if [ -n "$zone_temp" ]; then
		start_delta=$((configured_off_milli - zone_temp))
	fi
	load_ratio=$(compute_ratio "$zone_temp" "$configured_off_milli" "$configured_on_milli" "$configured_on_milli")
	supported=0
	if [ "$pwm_supported" = '1' ] && { [ "$thermal_supported" = '1' ] || [ -n "$zone_temp" ]; }; then
		supported=1
	elif [ "$trip_supported" = '1' ]; then
		supported=1
	fi

	if [ "$supported" != '1' ]; then
		if [ "$pwm_supported" != '1' ] && [ "$trip_supported" != '1' ]; then
			runtime_error='No writable pwm-fan hwmon interface or compatible fallback thermal trip point was detected.'
		elif [ "$thermal_supported" != '1' ] && [ -z "$zone_temp" ]; then
			runtime_error='No readable CPU thermal zone was detected.'
		fi
	fi

	json_add_boolean supported "$supported"
	if [ -n "$runtime_error" ]; then
		json_add_string error "$runtime_error"
	fi
	json_add_string zone "$ZONE"
	json_add_int trip_point "$trip_point_value"
	json_add_string thermal_type "$thermal_type"

	# Use safe helpers for potentially empty values
	if [ -n "$zone_temp" ]; then
		json_add_string zone_temp "$(milli_to_celsius "$zone_temp")"
	else
		json_add_string zone_temp ""
	fi
	if [ -n "$fan_on_temp" ]; then
		json_add_string fan_on_temp "$(milli_to_celsius "$fan_on_temp")"
	else
		json_add_string fan_on_temp ""
	fi
	if [ -n "$fan_off_temp" ]; then
		json_add_string fan_off_temp "$(milli_to_celsius "$fan_off_temp")"
	else
		json_add_string fan_off_temp ""
	fi
	if [ -n "$configured_on_milli" ]; then
		json_add_string configured_on_temp "$(milli_to_celsius "$configured_on_milli")"
	else
		json_add_string configured_on_temp ""
	fi
	if [ -n "$configured_off_milli" ]; then
		json_add_string configured_off_temp "$(milli_to_celsius "$configured_off_milli")"
	else
		json_add_string configured_off_temp ""
	fi
	json_add_string hysteresis ""
	if [ -n "$next_trip_temp" ]; then
		json_add_string next_trip_temp "$(milli_to_celsius "$next_trip_temp")"
	else
		json_add_string next_trip_temp ""
	fi
	if [ -n "$headroom" ]; then
		json_add_string headroom "$(milli_to_celsius "$headroom")"
	else
		json_add_string headroom ""
	fi
	if [ -n "$start_delta" ]; then
		json_add_string start_delta "$(milli_to_celsius "$start_delta")"
	else
		json_add_string start_delta ""
	fi
	json_add_string load_ratio "$load_ratio"
	json_add_string state "$state"
	json_add_boolean thermal_supported "$thermal_supported"
	json_add_boolean pwm_supported "$pwm_supported"
	json_add_boolean mode_supported "$mode_supported"
	json_add_string hwmon_name "$PWM_NAME"
	json_add_string hwmon_path "$PWM_HWMON"
	json_add_string pwm_raw "$PWM_RAW"
	json_add_string pwm_percent "$PWM_PERCENT"
	json_add_string pwm_enable_mode "$PWM_ENABLE"
	json_add_string fan_rpm "$display_fan_rpm"
	json_add_string actual_fan_rpm "$actual_fan_rpm"
	json_add_string estimated_fan_rpm "$estimated_fan_rpm"
	json_add_string rpm_source "$rpm_source"
	json_add_int fan_max_rpm "$configured_max_rpm"
	if [ -n "$configured_off_milli" ]; then
		json_add_string smart_min_temp "$(milli_to_celsius "$configured_off_milli")"
	else
		json_add_string smart_min_temp ""
	fi
	if [ -n "$configured_on_milli" ]; then
		json_add_string smart_max_temp "$(milli_to_celsius "$configured_on_milli")"
	else
		json_add_string smart_max_temp ""
	fi

	# Add PID parameters (base + tuned)
	read_pid_params
	read_adapt_state

	# Collect and add all thermal zones
	collect_all_thermal_zones

	# Collect and add all hwmon sensors
	collect_all_hwmon_sensors

	json_dump
	json_cleanup
}

case "$1" in
	list)
		json_init
		json_add_object getStatus
		json_close_object
		json_dump
		json_cleanup
		;;
	call)
		case "$2" in
			getStatus)
				get_status
				;;
		esac
		;;
esac
