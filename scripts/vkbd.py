#!/usr/bin/env python3
#
# vkbd.py -- a virtual USB keyboard on the MiSTer, for testing the core's
# Smart Keyboard path remotely (like the DataRover project's vpad.py).  Runs
# on the MiSTer; reads commands on stdin, one a line:
#
#   key NAME [ms]    press and release a key (hold ms, default 80)
#   down NAME / up NAME
#   type TEXT        a-z, 0-9 and space
#   sleep S          seconds
#
# NAME: a Linux KEY_ name without the prefix (A, ENTER, ESC, LEFTSHIFT,
# SPACE, BACKSPACE, UP, F1, KP1 ...).
import fcntl, os, struct, sys, time

UI_SET_EVBIT, UI_SET_KEYBIT = 0x40045564, 0x40045565
UI_DEV_CREATE, UI_DEV_DESTROY = 0x5501, 0x5502
EV_SYN, EV_KEY = 0, 1
KEYS = {
    "ESC": 1, "1": 2, "2": 3, "3": 4, "4": 5, "5": 6, "6": 7, "7": 8, "8": 9, "9": 10, "0": 11,
    "MINUS": 12, "EQUAL": 13, "BACKSPACE": 14, "TAB": 15, "Q": 16, "W": 17, "E": 18, "R": 19,
    "T": 20, "Y": 21, "U": 22, "I": 23, "O": 24, "P": 25, "LEFTBRACE": 26, "RIGHTBRACE": 27,
    "ENTER": 28, "LEFTCTRL": 29, "A": 30, "S": 31, "D": 32, "F": 33, "G": 34, "H": 35, "J": 36,
    "K": 37, "L": 38, "SEMICOLON": 39, "APOSTROPHE": 40, "GRAVE": 41, "LEFTSHIFT": 42,
    "BACKSLASH": 43, "Z": 44, "X": 45, "C": 46, "V": 47, "B": 48, "N": 49, "M": 50, "COMMA": 51,
    "DOT": 52, "SLASH": 53, "RIGHTSHIFT": 54, "SPACE": 57, "CAPSLOCK": 58, "F1": 59, "F12": 88,
    "KP1": 79, "KP2": 80, "KPPLUS": 78, "UP": 103, "LEFT": 105, "RIGHT": 106, "DOWN": 108,
}

fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_SYN)
for code in KEYS.values():
    fcntl.ioctl(fd, UI_SET_KEYBIT, code)
dev = struct.pack("80sHHHHi", b"VSmile remote keyboard", 3, 0x1234, 0x5678, 1, 0)
dev += b"\0" * (4 * 64 * 4)
os.write(fd, dev)
fcntl.ioctl(fd, UI_DEV_CREATE)
time.sleep(1.5)

def emit(code, value):
    os.write(fd, struct.pack("llHHi", 0, 0, EV_KEY, code, value))
    os.write(fd, struct.pack("llHHi", 0, 0, EV_SYN, 0, 0))

def tap(name, ms=80):
    emit(KEYS[name], 1); time.sleep(ms / 1000); emit(KEYS[name], 0); time.sleep(0.12)

for line in sys.stdin:
    p = line.split(maxsplit=1)
    if not p:
        continue
    cmd, arg = p[0], (p[1].strip() if len(p) > 1 else "")
    if cmd == "key":
        a = arg.split()
        tap(a[0], int(a[1]) if len(a) > 1 else 80)
    elif cmd == "down":
        emit(KEYS[arg], 1)
    elif cmd == "up":
        emit(KEYS[arg], 0)
    elif cmd == "type":
        for ch in arg:
            tap("SPACE" if ch == " " else ch.upper())
    elif cmd == "sleep":
        time.sleep(float(arg))
    print("ok", flush=True)

time.sleep(0.3)
fcntl.ioctl(fd, UI_DEV_DESTROY)
os.close(fd)
