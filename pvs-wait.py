#!/usr/bin/env python3
"""pvs-wait.py: play a game while IBM Cloud builds your lab.

Watches one resource in the background and lets you play until it is ready.
The moment it is ready, the game stops and tells you to get back to the lab.

Usage:
    python3 pvs-wait.py <what> [--quiet]

What to watch:
    workspace     PowerVS workspace $P-ws is active
    image         the AIX image copy in your workspace is active
    server        AIX server $AIX_ID is ACTIVE
    vsi           VPC server $P-vsi is running
    gateway       Transit Gateway $TG_ID is available
    connections   both Transit Gateway connections are attached
    ssh           the AIX server answers on port 22 at $AIX_IP

Variables come from your shell, or from ~/pvs-lab.env if they are not set.
--quiet skips the games and just prints status changes.

Games:
    1  Power Trivia    multiple choice on Power, AIX, and IBM Cloud
    2  Subnet Sprint   quick-fire CIDR maths
    3  Packet Snake    steer a packet round the network (arrow keys or WASD)

Only the Python standard library is used. No files are written except your
high scores in ~/.pvs-wait-scores.json.
"""
import ipaddress
import json
import os
import random
import select
import shlex
import socket
import subprocess
import sys
import threading
import time

POLL = int(os.environ.get('PVS_WAIT_POLL', '15'))
SCORES = os.path.expanduser('~/.pvs-wait-scores.json')
ENV_FILE = os.path.expanduser('~/pvs-lab.env')


# ---------------------------------------------------------------------------
# Environment: shell variables first, then ~/pvs-lab.env as a fallback
# ---------------------------------------------------------------------------
def load_env():
    env = {}
    try:
        with open(ENV_FILE) as f:
            for line in f:
                line = line.strip()
                if not line.startswith('export '):
                    continue
                for part in shlex.split(line[len('export '):]):
                    if '=' in part:
                        k, v = part.split('=', 1)
                        env[k] = v
    except OSError:
        pass
    env.update({k: v for k, v in os.environ.items() if v})
    return env


# ---------------------------------------------------------------------------
# What can be watched. Each entry: variables needed, a label, and a check
# function that returns (status_text, state) where state is
# 'ready', 'failed', or 'waiting'.
# ---------------------------------------------------------------------------
def ibm_json(args):
    out = subprocess.run(['ibmcloud'] + args, capture_output=True, text=True, timeout=90)
    if out.returncode != 0:
        raise RuntimeError((out.stderr or out.stdout).strip().splitlines()[-1:] or ['ibmcloud failed'])
    return json.loads(out.stdout)


def as_list(data, *keys):
    if isinstance(data, list):
        return data
    for k in keys:
        if isinstance(data, dict) and isinstance(data.get(k), list):
            return data[k]
    return []


def check_workspace(e):
    data = as_list(ibm_json(['resource', 'service-instance', e['P'] + '-ws', '--output', 'json']))
    state = (data[0].get('state') if data else None) or 'not listed yet'
    return state, 'ready' if state == 'active' else 'failed' if state in ('failed', 'removed') else 'waiting'


def check_image(e):
    imgs = as_list(ibm_json(['pi', 'image', 'list', '--json']), 'images')
    state = (imgs[0].get('state') if imgs else None) or 'copying'
    return state, 'ready' if state == 'active' else 'failed' if state in ('failed', 'error') else 'waiting'


def check_server(e):
    state = ibm_json(['pi', 'instance', 'get', e['AIX_ID'], '--json']).get('status', 'unknown')
    return state, 'ready' if state == 'ACTIVE' else 'failed' if state == 'ERROR' else 'waiting'


def check_vsi(e):
    state = ibm_json(['is', 'instance', e['P'] + '-vsi', '--output', 'json']).get('status', 'unknown')
    return state, 'ready' if state == 'running' else 'failed' if state == 'failed' else 'waiting'


def check_gateway(e):
    state = ibm_json(['tg', 'gateway', e['TG_ID'], '--output', 'json']).get('status', 'unknown')
    return state, 'ready' if state == 'available' else 'failed' if state == 'failed' else 'waiting'


def check_connections(e):
    conns = as_list(ibm_json(['tg', 'connections', e['TG_ID'], '--output', 'json']), 'connections')
    states = [c.get('status', '?') for c in conns]
    attached = sum(s == 'attached' for s in states)
    text = '%d of %d attached' % (attached, max(len(states), 2))
    if any(s == 'failed' for s in states):
        return text, 'failed'
    return text, 'ready' if len(states) >= 2 and attached == len(states) else 'waiting'


def check_ssh(e):
    try:
        with socket.create_connection((e['AIX_IP'], 22), timeout=5):
            return 'port 22 open', 'ready'
    except OSError:
        return 'port 22 not open yet', 'waiting'


WATCHES = {
    'workspace':   (['P'], lambda e: e['P'] + '-ws', check_workspace, 'about 5 to 15 minutes'),
    'image':       ([], lambda e: 'AIX image copy', check_image, 'a few minutes'),
    'server':      (['AIX_ID'], lambda e: e.get('P', 'your') + '-aix', check_server, 'about 15 to 20 minutes'),
    'vsi':         (['P'], lambda e: e['P'] + '-vsi', check_vsi, 'about a minute'),
    'gateway':     (['TG_ID'], lambda e: e.get('P', 'your') + '-tg', check_gateway, 'about a minute'),
    'connections': (['TG_ID'], lambda e: 'gateway connections', check_connections, 'a few minutes'),
    'ssh':         (['AIX_IP'], lambda e: 'SSH on ' + e['AIX_IP'], check_ssh, 'a few minutes'),
}


class Watcher(threading.Thread):
    """Polls the resource in the background. `done` is set when it is ready or failed."""

    def __init__(self, what, env):
        super().__init__(daemon=True)
        self.need, label_fn, self.check, self.typical = WATCHES[what]
        self.env, self.label = env, label_fn(env)
        self.status, self.state = 'checking...', 'waiting'
        self.started = time.time()
        self.done = threading.Event()
        self.changes = []          # (time, text) for status changes, read by the games

    def elapsed(self):
        s = int(time.time() - self.started)
        return '%dm%02ds' % (s // 60, s % 60)

    def run(self):
        while not self.done.is_set():
            try:
                text, state = self.check(self.env)
            except Exception as exc:  # network blips: keep trying
                text, state = 'checking (%s)' % str(exc)[:40], 'waiting'
            if text != self.status:
                self.changes.append((time.time(), text))
            self.status, self.state = text, state
            if state in ('ready', 'failed'):
                self.done.set()
                return
            self.done.wait(POLL)

    def line(self):
        return '%s: %s  (%s)' % (self.label, self.status, self.elapsed())


# ---------------------------------------------------------------------------
# High scores
# ---------------------------------------------------------------------------
def load_scores():
    try:
        with open(SCORES) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_score(game, score):
    scores = load_scores()
    best = scores.get(game, 0)
    if score > best:
        scores[game] = score
        try:
            with open(SCORES, 'w') as f:
                json.dump(scores, f)
        except OSError:
            pass
        return True, score
    return False, best


# ---------------------------------------------------------------------------
# Line input that gives up as soon as the watcher finishes
# ---------------------------------------------------------------------------
DIM, BOLD, GREEN, RED, CYAN, YELLOW, RESET = '\033[2m', '\033[1m', '\033[32m', '\033[31m', '\033[36m', '\033[33m', '\033[0m'
if not sys.stdout.isatty():
    DIM = BOLD = GREEN = RED = CYAN = YELLOW = RESET = ''


def status_bar(w):
    print('%s[ %s ]%s' % (DIM, w.line(), RESET))


def ask(prompt, w):
    """Read a line, or return None the moment the watcher is done."""
    seen = len(w.changes)
    sys.stdout.write(prompt)
    sys.stdout.flush()
    while True:
        if w.done.is_set():
            print()
            return None
        if len(w.changes) != seen:
            seen = len(w.changes)
            sys.stdout.write('\n%s[ %s ]%s\n%s' % (CYAN, w.line(), RESET, prompt))
            sys.stdout.flush()
        try:
            ready, _, _ = select.select([sys.stdin], [], [], 0.3)
        except (ValueError, OSError):
            w.done.wait()
            return None
        if ready:
            line = sys.stdin.readline()
            if line == '':          # stdin closed: nothing to play, just wait
                w.done.wait()
                return None
            return line.strip()


# ---------------------------------------------------------------------------
# Game 1: Power Trivia
# ---------------------------------------------------------------------------
TRIVIA = [
    ('What does LPAR stand for?',
     ['Logical partition', 'Linked processor array', 'Local private address range', 'Load-balanced partition'], 0,
     'An LPAR is a slice of a Power server that runs its own OS. Your AIX server is one.'),
    ('Which hypervisor runs PowerVS virtual servers?',
     ['KVM', 'PowerVM', 'ESXi', 'Hyper-V'], 1,
     'PowerVM is the firmware-based hypervisor on IBM Power servers.'),
    ('An AIX level of 7300-03-00 means:',
     ['AIX 7.3, Technology Level 3', 'AIX 7.0, build 3300', 'AIX 3.0, release 7', 'AIX 7.3, 300 days of patches'], 0,
     'The first four digits are the release (7300 = 7.3), then the Technology Level, then the Service Pack.'),
    ('Which command prints the exact AIX level?',
     ['uname -r', 'oslevel -s', 'cat /etc/os-release', 'lsb_release -a'], 1,
     'oslevel -s gives release, TL, SP, and build date.'),
    ('How many hardware threads can each Power10 core run (maximum SMT)?',
     ['2', '4', '8', '16'], 2,
     'Power10 supports SMT8: eight hardware threads per core.'),
    ('Is AIX big-endian or little-endian?',
     ['Big-endian', 'Little-endian', 'Both at once', 'It depends on the shell'], 0,
     'AIX is big-endian. Linux on Power today usually runs little-endian (ppc64le).'),
    ('What is the default login shell for root on AIX?',
     ['bash', 'zsh', 'ksh (Korn shell)', 'csh'], 2,
     'AIX uses the Korn shell, written by David Korn at Bell Labs.'),
    ('What does SMIT stand for on AIX?',
     ['System Management Interface Tool', 'Secure Machine Install Toolkit', 'Server Monitoring and Inventory Tracker',
      'Shell Menu Interface Terminal'], 0,
     'smit (or smitty in a terminal) is the menu-driven admin tool.'),
    ('Which AIX command shows the error log?',
     ['dmesg', 'journalctl', 'errpt', 'lslog'], 2,
     'errpt reads the AIX error log; errpt -a shows full details.'),
    ('What is the main AIX file system type?',
     ['ext4', 'JFS2', 'XFS', 'ZFS'], 1,
     'JFS2, the Enhanced Journaled File System.'),
    ('In what year did AIX first ship?',
     ['1986', '1992', '1999', '2004'], 0,
     'AIX version 1 shipped in 1986 for the IBM RT PC.'),
    ('IBM i was originally known as:',
     ['OS/2', 'OS/400', 'z/OS', 'MVS'], 1,
     'OS/400 ran on the AS/400; it became i5/OS and then IBM i.'),
    ('PowerVS storage tier3 gives how many IOPS per GB?',
     ['1', '3', '10', '25'], 1,
     'Tier 3 is 3 IOPS per GB. Tier 1 is 10, and Tier 0 is 25.'),
    ('What does PER stand for in PowerVS networking?',
     ['Private Edge Relay', 'Power Edge Router', 'Primary Ethernet Route', 'Partition Exchange Router'], 1,
     'A Power Edge Router lets a workspace attach straight to a Transit Gateway.'),
    ('What does CRN stand for in IBM Cloud?',
     ['Cloud Resource Name', 'Central Routing Node', 'Customer Reference Number', 'Compute Resource Network'], 0,
     'A CRN uniquely identifies every IBM Cloud resource. Transit Gateway attaches networks by CRN.'),
    ('A Transit Gateway with LOCAL routing connects networks:',
     ['Only within one region', 'Anywhere in the world', 'Only to on-premises', 'Only between two VPCs'], 0,
     'Local routing stays in one region. Global routing spans regions and costs more.'),
    ('What does VPC stand for?',
     ['Virtual Private Cloud', 'Very Private Compute', 'Virtual Partition Controller', 'Verified Public Connection'], 0,
     'A VPC is your own isolated network in IBM Cloud.'),
    ('Why does your VPC server need a floating IP?',
     ['To get a public internet address', 'To float between zones', 'To speed up the disk', 'To join the Transit Gateway'], 0,
     'A floating IP is a public address mapped to the server\'s private one.'),
    ('By default, a VPC security group lets inbound traffic in from:',
     ['Anywhere', 'Nowhere except members of the same group', 'Only port 22', 'Only the Transit Gateway'], 1,
     'That is why the lab adds a rule allowing SSH on port 22.'),
    ('What does jq\'s -r flag do?',
     ['Reverses the output', 'Prints raw strings, without quotes', 'Reads recursively', 'Retries on error'], 1,
     'Without -r, jq prints "strings" with their JSON quotes.'),
    ('What does -f do in "ibmcloud plugin install power-iaas -f"?',
     ['Fetches from a file', 'Skips the confirmation prompt', 'Forces a downgrade', 'Formats the output'], 1,
     'The -f flag answers "yes" for you.'),
    ('IBM Cloud region code for Toronto?',
     ['ca-tor', 'tor01', 'can-east', 'ca-on'], 0,
     'ca-tor is the Toronto multizone region.'),
    ('Which file holds the PUBLIC half of your lab key?',
     ['~/.ssh/pvs-lab', '~/.ssh/pvs-lab.pub', '~/.ssh/known_hosts', '~/.ssh/config'], 1,
     'The .pub file is safe to share. The private file never leaves Cloud Shell.'),
    ('The s1022 system type in PowerVS is:',
     ['A Power9 enterprise server', 'A Power10 scale-out server', 'An x86 server', 'A z16 mainframe'], 1,
     'The Power S1022 is a 2-socket Power10 scale-out server.'),
    ('Which processor type lets your LPAR use cores from a pool other LPARs also use?',
     ['Dedicated', 'Shared', 'Capped dedicated', 'Reserved'], 1,
     'Shared processors are the cheapest way to get a fraction of a core, like the 0.25 in this lab.'),
    ('What is the classic AIX command to list devices?',
     ['lsdev', 'lspci', 'devlist', 'showdev'], 0,
     'lsdev -Cc adapter lists the adapters, including your two network cards.'),
]


def play_trivia(w):
    print('\n%sPower Trivia%s  Answer with 1 to 4. Type q to go back to the menu.\n' % (BOLD, RESET))
    qs = TRIVIA[:]
    random.shuffle(qs)
    score = asked = 0
    for q, opts, correct, why in qs:
        order = list(range(4))
        random.shuffle(order)
        status_bar(w)
        print('%sQ%d.%s %s' % (BOLD, asked + 1, RESET, q))
        for i, o in enumerate(order):
            print('   %d) %s' % (i + 1, opts[o]))
        ans = ask('Your answer: ', w)
        if ans is None:
            break
        if ans.lower() == 'q':
            break
        asked += 1
        if ans in ('1', '2', '3', '4') and order[int(ans) - 1] == correct:
            score += 1
            print('%sCorrect!%s %s\n' % (GREEN, RESET, why))
        else:
            print('%sNot quite.%s It is "%s". %s\n' % (RED, RESET, opts[correct], why))
    if asked:
        new, best = save_score('trivia', score)
        print('%sScore: %d of %d.%s %s\n' % (BOLD, score, asked, RESET,
                                              'New personal best!' if new else 'Your best: %d.' % best))


# ---------------------------------------------------------------------------
# Game 2: Subnet Sprint
# ---------------------------------------------------------------------------
def sprint_question():
    kind = random.choice(['size', 'size', 'inside', 'bigger', 'network'])
    if kind == 'size':
        n = random.randint(20, 30)
        return 'How many addresses are in a /%d block?' % n, str(2 ** (32 - n)), \
            'A /%d leaves %d bits for hosts: 2^%d = %d.' % (n, 32 - n, 32 - n, 2 ** (32 - n))
    if kind == 'inside':
        n = random.choice([20, 22, 24, 26])
        net = ipaddress.ip_network('10.240.%d.0/%d' % (random.choice([0, 4, 8, 64]), n), strict=False)
        addr = net.network_address + random.randint(0, 2 * net.num_addresses)
        yes = addr in net
        return 'Is %s inside %s? (y/n)' % (addr, net), 'y' if yes else 'n', \
            '%s runs from %s to %s.' % (net, net.network_address, net.broadcast_address)
    if kind == 'bigger':
        a, b = random.sample(range(18, 31), 2)
        return 'Which holds more addresses, /%d or /%d? (type the number)' % (a, b), str(min(a, b)), \
            'Smaller prefix, bigger block: /%d has %d addresses, /%d has %d.' % (
                min(a, b), 2 ** (32 - min(a, b)), max(a, b), 2 ** (32 - max(a, b)))
    n = random.choice([25, 26, 27, 28])
    host = ipaddress.ip_address('192.168.50.%d' % random.randint(1, 254))
    net = ipaddress.ip_network('%s/%d' % (host, n), strict=False)
    return 'What is the network address of %s/%d?' % (host, n), str(net.network_address), \
        'A /%d splits into blocks of %d; %s falls in %s.' % (n, net.num_addresses, host, net)


def play_sprint(w):
    print('\n%sSubnet Sprint%s  Quick CIDR maths. Build a streak. Type q to go back to the menu.\n' % (BOLD, RESET))
    score = streak = best_streak = 0
    while True:
        q, answer, why = sprint_question()
        status_bar(w)
        ans = ask('%s%s%s  ' % (BOLD, q, RESET), w)
        if ans is None or ans.lower() == 'q':
            break
        if ans.lower().replace('/', '') == answer:
            score += 1
            streak += 1
            best_streak = max(best_streak, streak)
            print('%sYes!%s Streak %d. %s\n' % (GREEN, RESET, streak, why))
        else:
            streak = 0
            print('%sNo:%s the answer is %s. %s\n' % (RED, RESET, answer, why))
    if score or best_streak:
        new, best = save_score('sprint', best_streak)
        print('%sCorrect: %d. Longest streak: %d.%s %s\n' % (BOLD, score, best_streak, RESET,
                                                            'New personal best!' if new else 'Your best streak: %d.' % best))


# ---------------------------------------------------------------------------
# Game 3: Packet Snake (curses)
# ---------------------------------------------------------------------------
def play_snake(w):
    try:
        import curses
    except ImportError:
        print('Packet Snake needs the curses module, which this Python does not have. Try another game.\n')
        return
    try:
        result = curses.wrapper(_snake, w, curses)
    except curses.error:
        print('Your terminal is too small for Packet Snake. Make the window bigger, or try another game.\n')
        return
    if result is not None:
        new, best = save_score('snake', result)
        print('%sPackets delivered: %d.%s %s\n' % (BOLD, result, RESET,
                                                   'New personal best!' if new else 'Your best: %d.' % best))


def _snake(scr, w, curses):
    curses.curs_set(0)
    scr.keypad(True)
    if curses.has_colors():
        curses.start_color()
        curses.use_default_colors()
        curses.init_pair(1, curses.COLOR_GREEN, -1)
        curses.init_pair(2, curses.COLOR_MAGENTA, -1)
        curses.init_pair(3, curses.COLOR_CYAN, -1)
    green = curses.color_pair(1) | curses.A_BOLD
    pink = curses.color_pair(2) | curses.A_BOLD
    cyan = curses.color_pair(3)

    rows, cols = scr.getmaxyx()
    if rows < 14 or cols < 40:
        raise curses.error('too small')
    top, left, bottom, right = 2, 0, rows - 2, min(cols - 1, 79)
    keys = {curses.KEY_UP: (-1, 0), curses.KEY_DOWN: (1, 0), curses.KEY_LEFT: (0, -1), curses.KEY_RIGHT: (0, 1),
            ord('w'): (-1, 0), ord('s'): (1, 0), ord('a'): (0, -1), ord('d'): (0, 1)}
    hops = ['VPC', 'TGW', 'PER', 'LPAR', 'VSI', 'DNS', 'NIC', 'FIP']
    best_score = None

    while True:
        midr, midc = (top + bottom) // 2, (left + right) // 2
        body = [(midr, midc - i) for i in range(4)]
        direction = (0, 1)
        score = 0

        def new_food():
            while True:
                p = (random.randint(top + 1, bottom - 1), random.randint(left + 1, right - 1))
                if p not in body:
                    return p, random.choice(hops)
        food, label = new_food()
        alive = True
        while alive:
            if w.done.is_set():
                return best_score if best_score is not None else score
            scr.erase()
            scr.addnstr(0, 0, ' ' + w.line(), right, cyan)
            scr.addnstr(1, 0, ' Packet Snake  score %d   arrows/WASD to steer, q for menu' % score, right)
            for c in range(left, right + 1):
                scr.addch(top, c, ord('-'))
                scr.addch(bottom, c, ord('-'))
            for r in range(top, bottom + 1):
                scr.addch(r, left, ord('|'))
                scr.addch(r, right, ord('|'))
            scr.addstr(food[0], food[1], '*', pink)
            if food[1] + 2 + len(label) < right:
                scr.addstr(food[0], food[1] + 2, label, pink)
            for i, (r, c) in enumerate(body):
                scr.addch(r, c, ord('@') if i == 0 else ord('o'), green)
            scr.refresh()
            scr.timeout(max(55, 140 - score * 4))
            ch = scr.getch()
            if ch in (ord('q'), ord('Q')):
                return best_score if best_score is not None else score
            if ch in keys:
                nd = keys[ch]
                if (nd[0] + direction[0], nd[1] + direction[1]) != (0, 0):
                    direction = nd
            head = (body[0][0] + direction[0], body[0][1] + direction[1])
            if head[0] in (top, bottom) or head[1] in (left, right) or head in body:
                alive = False
                break
            body.insert(0, head)
            if head == food:
                score += 1
                food, label = new_food()
            else:
                body.pop()
        best_score = max(best_score or 0, score)
        msg = ' Packet dropped! %d delivered. r to retry, q for the menu ' % score
        scr.addstr((top + bottom) // 2, max(left + 1, (left + right - len(msg)) // 2), msg, pink | curses.A_REVERSE)
        scr.refresh()
        scr.timeout(300)
        while True:
            if w.done.is_set():
                return best_score
            ch = scr.getch()
            if ch in (ord('r'), ord('R')):
                break
            if ch in (ord('q'), ord('Q')):
                return best_score


# ---------------------------------------------------------------------------
# Quiet mode and the menu
# ---------------------------------------------------------------------------
FACTS = [
    'PowerVS servers are LPARs on real IBM Power hardware, run by the PowerVM hypervisor.',
    'Your private subnet 192.168.50.0/24 reaches the VPC through the Transit Gateway.',
    'Cloud Shell sits on the internet, which is why the AIX server also has a public subnet.',
    'A Transit Gateway attaches each network by its CRN.',
    'The image copy keeps the stock name because stock image names cannot be changed.',
]


def quiet(w):
    print('Waiting quietly. Status changes print below. Ctrl+C stops watching (the build keeps going).')
    last, tick = None, 0
    while not w.done.wait(1):
        if w.status != last:
            last = w.status
            print('%s  %s' % (time.strftime('%H:%M:%S'), w.line()))
        tick += 1
        if tick % 90 == 0:
            print('%s  %sDid you know?%s %s' % (time.strftime('%H:%M:%S'), DIM, RESET, random.choice(FACTS)))


def menu(w):
    while not w.done.is_set():
        scores = load_scores()
        print('\n%sWhile you wait%s (usually %s):' % (BOLD, RESET, w.typical))
        print('   1) Power Trivia     best %s' % scores.get('trivia', '-'))
        print('   2) Subnet Sprint    best streak %s' % scores.get('sprint', '-'))
        print('   3) Packet Snake     best %s' % scores.get('snake', '-'))
        print('   w) just wait quietly')
        status_bar(w)
        choice = ask('Pick one: ', w)
        if choice is None:
            return
        choice = choice.lower()
        if choice == '1':
            play_trivia(w)
        elif choice == '2':
            play_sprint(w)
        elif choice == '3':
            play_snake(w)
        elif choice in ('w', 'q'):
            quiet(w)
            return


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('-')]
    if '-h' in sys.argv or '--help' in sys.argv or len(args) != 1 or args[0] not in WATCHES:
        print(__doc__.split('Games:')[0].strip())
        sys.exit(0 if ('-h' in sys.argv or '--help' in sys.argv) else 1)
    what = args[0]
    env = load_env()
    missing = [k for k in WATCHES[what][0] if not env.get(k)]
    if missing:
        print('%sMissing %s.%s Run "source ~/pvs-lab.env" or finish the earlier commands, then try again.'
              % (RED, ', '.join('$' + m for m in missing), RESET))
        sys.exit(1)

    w = Watcher(what, env)
    w.start()
    print('%sWatching %s.%s It will tell you the moment it is ready.' % (BOLD, w.label, RESET))
    w.done.wait(3)                  # a quick first look: maybe it is ready already
    try:
        if not w.done.is_set():
            if '--quiet' in sys.argv or not sys.stdin.isatty():
                quiet(w)
            else:
                menu(w)
            w.done.wait()
    except KeyboardInterrupt:
        print('\nStopped watching after %s. %s keeps building; rerun this command to keep watching.'
              % (w.elapsed(), w.label))
        sys.exit(130)

    if w.state == 'ready':
        print('\a\n%s%s  READY: %s, %s, after %s.  %s' % (GREEN, BOLD, w.label, w.status, w.elapsed(), RESET))
        print('Back to the lab: run the next command on the page.\n')
        sys.exit(0)
    print('\n%s%s  %s reports %s.  %s Ask a lab assistant.\n' % (RED, BOLD, w.label, w.status, RESET))
    sys.exit(2)


if __name__ == '__main__':
    main()
