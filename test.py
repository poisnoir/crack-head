from cffi import FFI
import time

ffi = FFI()

ffi.cdef("""
    int KCPDial(char* addr, char* key, int dataShards, int parityShards);
    int KCPSend(int id, char* data, int length);
    int KCPRecv(int id, char* buf, int maxLen);
    void KCPClose(int id);
""")

lib = ffi.dlopen("./kcplib.so")

print("--- Connecting ---")
conn_id = lib.KCPDial(b"127.0.0.1:6969", b"meow", 10, 3)

if conn_id < 0:
    print("Failed to connect")
    exit(1)

print(f"Connected! ID: {conn_id}")

msg = b"Hello from Python!"
sent = lib.KCPSend(conn_id, msg, len(msg))
print(f"Sent {sent} bytes")

# 2. Receive data
# We create a persistent buffer to hold the response
buf = ffi.new("char[1024]")

print("Waiting for response...")
# KCPRecv is blocking in your Go code, so Python will wait here
n = lib.KCPRecv(conn_id, buf, 1024)

if n > 0:
    # ffi.string(buf, n) converts the raw C buffer into a Python bytes object
    received_data = ffi.string(buf, n)
    print("Received:", received_data.decode('utf-8'))
else:
    print("No data received or error.")

# 3. Cleanup
lib.KCPClose(conn_id)
print("Closed.")