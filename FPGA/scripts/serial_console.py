"""Bounded UART transport for the existing ZCU106 Linux console."""
import base64
import re
import shlex
import time
import uuid

import serial


class Console:
    def __init__(self, port="COM17"):
        self.port = serial.Serial(port, 115200, timeout=0.2, write_timeout=5)

    def __enter__(self):
        return self

    def __exit__(self, *args):
        try:
            self.port.write(b"stty echo\r")
        finally:
            self.port.close()

    def command(self, command, timeout=30, on_output=None):
        marker = "MNIST_" + uuid.uuid4().hex
        self.port.write(b"stty -echo; bind 'set enable-bracketed-paste off'\r")
        time.sleep(0.15)
        self.port.read(self.port.in_waiting)
        self.port.write((command + "; printf '\\n" + marker + ":%s\\n' \"$?\"\r").encode())
        pattern = re.compile(rb"(?:^|[\r\n])" + marker.encode() + rb":(\d+)[\r\n]")
        output = b""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            chunk = self.port.read(min(max(self.port.in_waiting, 1), 65536))
            output += chunk
            if chunk and on_output is not None:
                on_output(chunk.decode(errors="replace"))
            match = pattern.search(output)
            if match:
                text = output[:match.start()].decode(errors="replace")
                if int(match[1]):
                    raise RuntimeError(text)
                return text
        raise TimeoutError(output.decode(errors="replace")[-4000:])

    def upload(self, data, path):
        encoded_path = shlex.quote(path + ".b64")
        self.command(": > " + encoded_path)
        encoded = base64.b64encode(data).decode()
        for start in range(0, len(encoded), 1800):
            self.command("printf '%s' " + shlex.quote(encoded[start:start + 1800])
                         + " >> " + encoded_path)
        self.command("base64 -d " + encoded_path + " > " + shlex.quote(path))

    def download(self, path, timeout=60):
        text = self.command("printf 'DATA:'; base64 -w0 " + shlex.quote(path)
                            + "; printf '\\n'", timeout)
        match = re.search(r"DATA:([A-Za-z0-9+/=]+)", text)
        if not match:
            raise ValueError("Board response did not contain the requested file")
        return base64.b64decode(match[1], validate=True)
