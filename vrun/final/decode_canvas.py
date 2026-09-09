import base64, json, sys

def decode(txt_path, png_path):
    with open(txt_path) as f:
        raw = f.read().strip()
    data = json.loads(raw)
    prefix = "data:image/png;base64,"
    assert data.startswith(prefix), data[:60]
    b64 = data[len(prefix):]
    png = base64.b64decode(b64)
    with open(png_path, 'wb') as f:
        f.write(png)
    return len(png)

if __name__ == "__main__":
    n = decode(sys.argv[1], sys.argv[2])
    print(n)
