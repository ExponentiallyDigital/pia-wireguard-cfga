
#!/bin/bash

green() { echo -e "\e[32m✔ $1\e[0m"; }
red()   { echo -e "\e[31m✖ $1\e[0m"; }

echo "=== VERIFYING LAPTOP BUILD OPTIMISATIONS ==="

# 1. Check tmpfs for Gradle cache
if mount | grep -q "/home/andrew/.gradle/caches type tmpfs"; then
    green "Gradle cache tmpfs mounted"
else
    red "Gradle cache tmpfs NOT mounted"
fi

# 2. Check tmpfs for /tmp
if mount | grep -q "/tmp type tmpfs"; then
    green "/tmp tmpfs mounted"
else
    red "/tmp tmpfs NOT mounted"
fi

# 3. Check readahead on /dev/sda5
echo "DEBUG: running blockdev on /dev/sda5"
RA=$(sudo blockdev --getra /dev/sda5)
echo "DEBUG: RA='$RA'"
if [ "$RA" = "4096" ]; then
    green "Readahead on /dev/sda5 = 4096"
else
    red "Readahead incorrect (got $RA)"
fi

# 4. Check I/O scheduler for /dev/sda
SCHED=$(cat /sys/block/sda/queue/scheduler 2>/dev/null)
if echo "$SCHED" | grep -q "

\[deadline\]

"; then
    green "I/O scheduler = deadline"
else
    red "I/O scheduler NOT deadline ($SCHED)"
fi

# 5. Check zram config
if [[ -f /etc/systemd/zram-generator.conf ]]; then
    if grep -q "zram-size" /etc/systemd/zram-generator.conf; then
        green "zram-generator.conf exists and configured"
    else
        red "zram-generator.conf exists but missing settings"
    fi
else
    red "zram-generator.conf missing"
fi

# 6. Check sysctl values
check_sysctl() {
    local key=$1
    local expected=$2
    local actual=$(sysctl -n $key 2>/dev/null)
    if [[ "$actual" == "$expected" ]]; then
        green "$key = $expected"
    else
        red "$key incorrect: expected $expected got $actual"
    fi
}

check_sysctl vm.swappiness 20
check_sysctl vm.vfs_cache_pressure 50
check_sysctl vm.dirty_background_ratio 5
check_sysctl vm.dirty_ratio 20
check_sysctl vm.dirty_writeback_centisecs 1500
check_sysctl vm.page-cluster 3
check_sysctl fs.inotify.max_user_watches 524288
check_sysctl fs.inotify.max_user_instances 1024

# 7. Check limits.conf
if grep -q "andrew soft nofile 524288" /etc/security/limits.conf &&
   grep -q "andrew hard nofile 524288" /etc/security/limits.conf; then
    green "limits.conf nofile entries correct"
else
    red "limits.conf nofile entries missing or incorrect"
fi

# 8. Check global Gradle daemon
if [[ -f /home/andrew/.gradle/gradle.properties ]] &&
   grep -q "org.gradle.daemon=true" /home/andrew/.gradle/gradle.properties; then
    green "Global Gradle daemon enabled"
else
    red "Global Gradle daemon NOT enabled"
fi

# 9. Check project gradle.properties
GP="../android/gradle.properties"
if [[ -f "$GP" ]]; then
    REQUIRED_KEYS=(
        "org.gradle.jvmargs"
        "org.gradle.workers.max=2"
        "org.gradle.caching=true"
        "kotlin.daemon.jvmargs=-Xmx1g"
        "org.gradle.parallel=true"
        "kotlin.incremental=true"
        "android.enableDexingArtifactTransform=true"
    )

    ALL_OK=true
    for key in "${REQUIRED_KEYS[@]}"; do
        if grep -q "$key" "$GP"; then
            green "gradle.properties: $key"
        else
            red "gradle.properties missing: $key"
            ALL_OK=false
        fi
    done
else
    red "./android/gradle.properties missing"
fi

echo "=== VERIFICATION COMPLETE ==="
