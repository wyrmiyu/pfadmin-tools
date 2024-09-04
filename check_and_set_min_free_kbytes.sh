#!/bin/bash

# Author: Sandi Wallendahl <sandi@redhat.com>
# License: MIT
# Copyright 2024 Red Hat, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the “Software”), to
# deal in the Software without restriction, including without limitation the
# rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
# sell copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
# IN THE SOFTWARE.

# This script is used to verify if the system meets the requirements to change
# the vm.min_free_kbytes value and to set the new value if the conditions are
# met.
#
# Exit codes:
#   0: Success
#   1: Failure in execution
#   2: Conditions not met

set -e -o pipefail

# Check if the script is run as root
if (( EUID != 0 )); then
  echo "This script must be run as root."
  exit 1
fi

# The new value for vm.min_free_kbytes is set with the following:
#   - If the NEW_MIN_FREE_KBYTES_VALUE is set as an environment variable, its
#     value will be used as the new vm.min_free_kbytes value.
#   - Otherwise, the script defaults to 262144 (256MB)
declare -ir NEW_MIN_FREE_KBYTES_VALUE="${NEW_MIN_FREE_KBYTES_VALUE:-262144}"

# The factor for the required memory is set with the following.
# This is the minimum multiple of the new vm.min_free_kbytes value that
# should be available in memory. A value between 3 and 7 is recommended.
#  - If the REQUIRED_MEM_FACTOR is set as an environment variable, its value
#    will be used as the required memory factor.
#  - Otherwise, the script defaults to 7.
declare -ir REQUIRED_MEM_FACTOR="${REQUIRED_MEM_FACTOR:-7}" # Recommended: 3-7

# The kernel default minimum free kbytes value
declare -ir kernel_default_min_free_kbytes=67584

# Maximum percentage of total memory that can be used for the new value
declare -ir max_mem_percent=20

# Variables for various values
declare -i current_min_free_kbytes max_value_for_min_free_kbytes
declare -i mem_free buffers cached swap_total swap_free
declare -i swap_util_pc mem_available required_mem
declare _msg

# Needed available memory based on 7x the new vm.min_free_kbytes value
required_mem="$((NEW_MIN_FREE_KBYTES_VALUE * REQUIRED_MEM_FACTOR))"

# Get statistics from /proc/meminfo
mem_total="$(grep -i '^MemTotal:' /proc/meminfo | awk '{print $2}')"
mem_free="$(grep -i '^MemFree:' /proc/meminfo | awk '{print $2}')"
buffers="$(grep -i '^Buffers:' /proc/meminfo | awk '{print $2}')"
cached="$(grep -i '^Cached:' /proc/meminfo | awk '{print $2}')"
swap_total="$(grep -i '^SwapTotal:' /proc/meminfo | awk '{print $2}')"
swap_free="$(grep -i '^SwapFree:' /proc/meminfo | awk '{print $2}')"

# Check if MemAvailable is defined in /proc/meminfo
if grep -q '^MemAvailable:' /proc/meminfo; then
  mem_available="$(grep -i '^MemAvailable:' /proc/meminfo | awk '{print $2}')"
else
  # Calculate MemAvailable if not defined in /proc/meminfo
  echo "MemAvailable not defined in /proc/meminfo, calculating manually."
  mem_available="$((mem_free + buffers + cached))"
fi

# Check if swap is disabled
if (( swap_total == 0 )); then
  swap_util_pc=0
else
  # Calculate current swap utilization percentage
  swap_util_pc="$((100 - 100 * swap_free / swap_total))"
fi

# Check if the new value is less than the kernel default
if (( NEW_MIN_FREE_KBYTES_VALUE < kernel_default_min_free_kbytes )); then
  _msg+="The new value of vm.min_free_kbytes ($NEW_MIN_FREE_KBYTES_VALUE) "
  _msg+="is less than the kernel default ($kernel_default_min_free_kbytes). "
  _msg+="If you really want to set such value, please do so manually."
  echo -e "$_msg"
  exit 2
fi

# Check if the new vm.min_free_kbytes value is already set
current_min_free_kbytes="$(sysctl -n vm.min_free_kbytes)"
if (( current_min_free_kbytes == NEW_MIN_FREE_KBYTES_VALUE )); then
  _msg+="The current value of vm.min_free_kbytes is already set to "
  _msg+="$NEW_MIN_FREE_KBYTES_VALUE.\nNo changes made."
  echo -e "$_msg"
  exit 0
fi

# Check if the new value is within the maximum memory percentage
max_value_for_min_free_kbytes="$((mem_total * max_mem_percent / 100))"
if (( NEW_MIN_FREE_KBYTES_VALUE > max_value_for_min_free_kbytes )); then
  _msg+="The new value of vm.min_free_kbytes ($NEW_MIN_FREE_KBYTES_VALUE) "
  _msg+="is greater than $max_value_for_min_free_kbytes, which is more than "
  _msg+="$max_mem_percent% of the total memory ($mem_total KB).\n"
  _msg+="If you really want to set such value, please do so manually."
  echo -e "$_msg"
  exit 2
fi

_msg+="The following conditions must be met in order "
_msg+="to change the vm.min_free_kbytes value:\n"
_msg+="1. Less than 50% of swap is utilized (currently: $swap_util_pc%).\n"
_msg+="2. Total available memory (currently: $mem_available KB) is at least "
_msg+="$REQUIRED_MEM_FACTOR times the new vm.min_free_kbytes value "
_msg+="($NEW_MIN_FREE_KBYTES_VALUE KB).\n\n"

# Condition check, fail the script if swap utilization is 50% or more, or
# the requirement for available memory is not met.
if (( swap_util_pc >= 50 )) || (( mem_available < required_mem )); then
  _msg+="WARNING: Conditions are not met. Please check the following:\n"
  _msg+="  MemTotal: $mem_total KB\n"
  _msg+="  MemFree: $mem_free KB\n"
  _msg+="  Buffers: $buffers KB\n"
  _msg+="  Cached: $cached KB\n"
  _msg+="  Available Memory: $mem_available KB\n"
  _msg+="  SwapTotal: $swap_total KB\n"
  _msg+="  SwapFree: $swap_free KB\n"
  _msg+="  Swap Utilization-%: $swap_util_pc%\n"
  _msg+="  Required available memory: $required_mem KB\n"
  _msg+="No changes made."
  echo -e "$_msg"
  exit 2
fi

_msg+="Conditions are met, running the following to set the new value:\n"
_msg+="  sysctl -w vm.min_free_kbytes=$NEW_MIN_FREE_KBYTES_VALUE\n"
echo -e "$_msg"

if ! sysctl -w vm.min_free_kbytes="$NEW_MIN_FREE_KBYTES_VALUE"; then
  echo "Failed to set vm.min_free_kbytes."
  exit 1
fi

exit 0
