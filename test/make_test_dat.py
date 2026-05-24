#!/usr/bin/env python3
"""Create a minimal synthetic Synology debug archive for testing."""

import io
import os
import sys
import tarfile

# Files inside the archive (all under dsm/)
FILES = {
    "dsm/etc.defaults/synoinfo.conf": """\
upnpmodelname="DS920+"
unique="synology_geminilake_920+"
""",
    "dsm/etc/synoinfo.conf": """\
upnpmodelname="DS920+"
unique="synology_geminilake_920+"
""",
    "dsm/etc.defaults/VERSION": """\
productversion="7.2.2"
buildnumber="72806"
smallfixnumber="4"
""",
    "dsm/etc/hostname": "TestNAS\n",
    "dsm/etc/ntp.conf": """\
server time.google.com.conf iburst
driftfile /var/lib/ntp/ntp.drift
""",
    "dsm/proc/mounts": """\
/dev/md0 / ext4 rw,relatime 0 0
/dev/vg1001/lv device-mapper/vg1001 btrfs rw,relatime 0 0
tmpfs /tmp tmpfs rw 0 0
/dev/md2 /volume1 btrfs rw,relatime 0 0
""",
    "dsm/proc/mdstat": """\
Personalities : [raid1] [raid6] [raid5] [raid4] [linear] [multipath] [raid0] [raid10]
md0 : active raid1 sda1[0] sdb1[1]
      2097088 blocks super 1.2 [2/2] [UU]

md1 : active raid1 sda2[0] sdb2[1]
      4195328 blocks super 1.2 [2/2] [UU]

md2 : active raid1 sda5[0] sdb5[1]
      5857423360 blocks super 1.2 [2/2] [UU]

unused devices: <none>
""",
    "dsm/proc/cpuinfo": """\
processor	: 0
vendor_id	: GenuineIntel
model name	: Intel(R) Celeron(R) J4125 CPU @ 2.00GHz
cpu MHz		: 2000.000
cache size	: 4096 KB

processor	: 1
vendor_id	: GenuineIntel
model name	: Intel(R) Celeron(R) J4125 CPU @ 2.00GHz
cpu MHz		: 2000.000
cache size	: 4096 KB

processor	: 2
vendor_id	: GenuineIntel
model name	: Intel(R) Celeron(R) J4125 CPU @ 2.00GHz
cpu MHz		: 2000.000
cache size	: 4096 KB

processor	: 3
vendor_id	: GenuineIntel
model name	: Intel(R) Celeron(R) J4125 CPU @ 2.00GHz
cpu MHz		: 2000.000
cache size	: 4096 KB
""",
    "dsm/proc/sys/kernel/syno_serial": "2330ABC123\n",
    "dsm/proc/sys/kernel/syno_CPU_info_core": "4\n",
    "dsm/var/log/messages": """\
2024-01-15T08:00:00+01:00 TestNAS kernel: Linux version 4.4.302+ (root@build7) (gcc version 7.5.0)
2024-01-15T08:00:01+01:00 TestNAS kernel: syno_hw_version=DS920+v10
""",
    "dsm/var/log/kern.log": """\
[    0.000000] Linux version 4.4.302+ (root@build7) (gcc version 7.5.0) #72806 SMP Mon Jan 15 00:00:00 CST 2024
[    0.000000] syno_hw_version=DS920+v10
[    0.001000] Model: DS920+
""",
    "dsm/var/log/synolog/synosys.log": """\
2024/01/15 08:00:00  SYSTEM   system   info    System booted successfully
2024/01/15 08:00:05  SYSTEM   system   info    DSM 7.2.2-72806 Update 4 started
""",
    "dsm/result/df.result": """\
Filesystem                Size  Used Avail Use% Mounted on
/dev/md0                 1.9G  983M  825M  55% /
/dev/vg1001/lv           2.0G  780M  1.1G  42% /volume2
/dev/md2                 5.3T  2.1T  3.2T  40% /volume1
tmpfs                     16G     0   16G   0% /dev/shm
""",
    "dsm/result/ifconfig.result": """\
eth0: flags=4163<UP,BROADCAST,RUNNING,MULTICAST>  mtu 1500
        inet 192.168.1.101  netmask 255.255.255.0  broadcast 192.168.1.255
        RX packets 12345678  bytes 9876543210 (9.8 GB)
        RX errors 0  dropped 0  overruns 0  frame 0
        TX packets 9876543  bytes 1234567890 (1.2 GB)
        TX errors 0  dropped 0  overruns 0  carrier 0  collisions 0

lo: flags=73<UP,LOOPBACK,RUNNING>  mtu 65536
        inet 127.0.0.1  netmask 255.0.0.0
        RX packets 1000  bytes 100000 (100.0 KB)
        RX errors 0  dropped 0  overruns 0  frame 0
        TX packets 1000  bytes 100000 (100.0 KB)
        TX errors 0  dropped 0  overruns 0  carrier 0  collisions 0
""",
    "dsm/result/uptime.result": """\
 08:00:00 up 42 days, 16:27,  load average: 0.12, 0.08, 0.06
""",
    "dsm/result/sda.result": """\
smartctl 7.2 2020-12-30 r5155 [x86_64-linux-4.4.302+] (local build)
Copyright (C) 2002-20, Bruce Allen, Christian Franke, www.smartmontools.org

=== START OF INFORMATION SECTION ===
Model Family:     Western Digital Red
Device Model:     WDC WD40EFAX-68JH4N0
Serial Number:    WD-ABC123456789
Firmware Version: 82.00A82
User Capacity:    4,000,787,030,016 bytes [4.00 TB]
Sector Size:      512 bytes logical/physical
Rotation Rate:    5400 rpm
Form Factor:      3.5 inches
SMART support is: Enabled

=== START OF READ SMART DATA SECTION ===
SMART overall-health self-assessment test result: PASSED

SMART Attributes Data Structure revision number: 16
Vendor Specific SMART Attributes with Thresholds:
ID# ATTRIBUTE_NAME          FLAG     VALUE WORST THRESH TYPE      UPDATED  WHEN_FAILED RAW_VALUE
  1 Raw_Read_Error_Rate     0x002f   200   200   051    Pre-fail  Always       -       0
  3 Spin_Up_Time            0x0027   189   181   021    Pre-fail  Always       -       5008
  4 Start_Stop_Count        0x0032   100   100   000    Old_age   Always       -       42
  5 Reallocated_Sector_Ct   0x0033   200   200   140    Pre-fail  Always       -       0
  7 Seek_Error_Rate         0x002e   200   200   000    Old_age   Always       -       0
  9 Power_On_Hours          0x0032   079   079   000    Old_age   Always       -       15821
 10 Spin_Retry_Count        0x0032   100   100   000    Old_age   Always       -       0
 12 Power_Cycle_Count       0x0032   100   100   000    Old_age   Always       -       42
192 Power-Off_Retract_Count  0x0032  200   200   000    Old_age   Always       -       35
193 Load_Cycle_Count        0x0032   183   183   000    Old_age   Always       -       52638
194 Temperature_Celsius     0x0022   120   105   000    Old_age   Always       -       30
196 Reallocated_Event_Count  0x0032  200   200   000    Old_age   Always       -       0
197 Current_Pending_Sector  0x0032   200   200   000    Old_age   Always       -       0
198 Offline_Uncorrectable   0x0030   100   253   000    Old_age   Offline      -       0
199 UDMA_CRC_Error_Count    0x0032   200   200   000    Old_age   Always       -       0
200 Multi_Zone_Error_Rate   0x0008   200   200   000    Old_age   Offline      -       0

SMART Error Log Version: 1
No Errors Logged

SMART Self-test log structure revision number 1
Num  Test_Description    Status                  Remaining  LifeTime(hours)  LBA_of_first_error
# 1  Extended offline    Completed without error       00%     15800         -
""",
    "dsm/result/sdb.result": """\
smartctl 7.2 2020-12-30 r5155 [x86_64-linux-4.4.302+] (local build)
Copyright (C) 2002-20, Bruce Allen, Christian Franke, www.smartmontools.org

=== START OF INFORMATION SECTION ===
Model Family:     Western Digital Red
Device Model:     WDC WD40EFAX-68JH4N0
Serial Number:    WD-XYZ987654321
Firmware Version: 82.00A82
User Capacity:    4,000,787,030,016 bytes [4.00 TB]
Sector Size:      512 bytes logical/physical
Rotation Rate:    5400 rpm
Form Factor:      3.5 inches
SMART support is: Enabled

=== START OF READ SMART DATA SECTION ===
SMART overall-health self-assessment test result: PASSED

SMART Attributes Data Structure revision number: 16
Vendor Specific SMART Attributes with Thresholds:
ID# ATTRIBUTE_NAME          FLAG     VALUE WORST THRESH TYPE      UPDATED  WHEN_FAILED RAW_VALUE
  1 Raw_Read_Error_Rate     0x002f   200   200   051    Pre-fail  Always       -       0
  5 Reallocated_Sector_Ct   0x0033   200   200   140    Pre-fail  Always       -       0
  9 Power_On_Hours          0x0032   079   079   000    Old_age   Always       -       15820
194 Temperature_Celsius     0x0022   120   105   000    Old_age   Always       -       31
197 Current_Pending_Sector  0x0032   200   200   000    Old_age   Always       -       0
198 Offline_Uncorrectable   0x0030   100   253   000    Old_age   Offline      -       0

SMART Self-test log structure revision number 1
Num  Test_Description    Status                  Remaining  LifeTime(hours)  LBA_of_first_error
# 1  Extended offline    Completed without error       00%     15800         -
""",
    "dsm/packages.list": """\
SynoCommunity	2.4.3	  enabled
SurveillanceStation	9.2.1	  enabled
Docker	20.10.3-1308	  enabled
HyperBackup	4.0.3-3516	  enabled
DownloadStation	3.8.17-3967	  enabled
total 5 packages installed
""",
    "dsm/result/syno_service.result": """\
Docker running enabled
HyperBackup running enabled
DownloadStation running enabled
SurveillanceStation running enabled
""",
    "dsm/var/log/hibernation.log": """\
2024/01/15 08:00:00 Hibernation check started
2024/01/15 08:00:01 HDDs active, not hibernating
""",
    "dsm/result/free.result": """\
              total        used        free      shared  buff/cache   available
Mem:       16384000     4123456    10234567      123456     2025977    11234567
Swap:       4194304      102400     4091904
""",
    "dsm/result/route.result": """\
Kernel IP routing table
Destination     Gateway         Genmask         Flags Metric Ref    Use Iface
0.0.0.0         192.168.1.1     0.0.0.0         UG    0      0        0 eth0
192.168.1.0     0.0.0.0         255.255.255.0   U     0      0        0 eth0
""",
    "dsm/result/uptime.result": """\
 08:00:00 up 42 days, 16:27,  load average: 0.12, 0.08, 0.06
""",
    "dsm/result/dmidecode.result": """\
# dmidecode 3.3
BIOS Information
\tVendor: American Megatrends Inc.
\tVersion: S4.0D0
\tRelease Date: 01/10/2024
\tBIOS Revision: 5.14
""",
    "dsm/result/dmesg.result": """\
[    0.000000] Linux version 4.4.302+
[    0.100000] synobios: load, DS920+
""",
    "dsm/var/log/bash_history.log": """\
ls -la
cat /proc/mdstat
""",
    "dsm/proc/sys/kernel/syno_hw_version": "DS920+\n",
    "dsm/var/log/disk.log": """\
2024-01-15 08:00:01 sda: PASSED
2024-01-15 08:00:01 sdb: PASSED
""",
}


def make_dat(output_path: str):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for arcname, content in FILES.items():
            data = content.encode()
            ti = tarfile.TarInfo(name=arcname)
            ti.size = len(data)
            tf.addfile(ti, io.BytesIO(data))
    with open(output_path, "wb") as f:
        f.write(buf.getvalue())
    print(f"Created {output_path} ({os.path.getsize(output_path)} bytes, {len(FILES)} files)")


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "debug_test.dat"
    make_dat(out)
