#!/usr/bin/env python
# -*- coding: utf-8 -*-

# Scriptname: synoPowerSchedule
# Script zum Umrechnen des DSM Power Schedule Values (/etc/power_sched.conf)
# Knowledgebase Artikel: https://css.synology.com/knowledge/1818
# Paketabhängigkeiten: Pyhton 3
# 2016, Dominic Platen

import argparse

def main():
    parser = argparse.ArgumentParser(description="Converts the power_sched.conf value to a readable format.")
    parser.add_argument("schedulevalue", help="The power_sched.conf value.", type=int)
    args = parser.parse_args()

    try:
        powerSchedValue = int(args.schedulevalue)
    except ValueError:
        print("Error: Value needs to be an integer.")

    print("\nPowerShedule for %#02d:" % (powerSchedValue))
    powerSchedValue = hex(powerSchedValue)[2:].zfill(7)

    if(int(powerSchedValue[0])):
        print("Power Schedule enabled")
    else:
        print("Power Schedule disabled")

    powerSchedDay = bin(int(powerSchedValue[1:3], 16))[2:].zfill(7)

    weekdays = ["Saturday", "Friday", "Thursday", "Wednesday", "Tuesday", "Monday", "Sunday"]

    for i in range(7):
        if(int(powerSchedDay[i])):
            print(weekdays[i] +": \tx")
        else:
            print(weekdays[i] +":")

    powerSchedHour = int(powerSchedValue[3:5], 16)
    powerSchedMin = int(powerSchedValue[5:7], 16)

    print("Scheduled Time: %#02d:%#02d" % (powerSchedHour, powerSchedMin))

if __name__ == "__main__":
    main()
