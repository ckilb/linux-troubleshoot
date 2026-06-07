journalctl -b 0 -k | grep -iE 'PM: suspend (entry|exit)|PM: resume|apple_bce|aaudio|page fault|Oops|FORCED_RMMOD' | tail -100
