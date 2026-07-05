import cbor2
import os
import glob
from datetime import datetime

def get_latest_cbor(directory):
    """获取最新的 .cbor 文件"""
    pattern = os.path.join(directory, "*.cbor")
    files = glob.glob(pattern)
    if not files:
        return None
    return max(files, key=os.path.getmtime)

def extract_strings_from_bytes(obj):
    """递归提取 bytes 中的 UTF-8 字符串"""
    strings = []
    
    if isinstance(obj, bytes):
        try:
            decoded = obj.decode('utf-8')
            # 只保留可打印字符（过滤控制字符）
            if any(c.isprintable() or c == '\n' for c in decoded):
                strings.append(decoded)
        except:
            pass
            
    elif isinstance(obj, list):
        for item in obj:
            strings.extend(extract_strings_from_bytes(item))
            
    elif isinstance(obj, dict):
        for value in obj.values():
            strings.extend(extract_strings_from_bytes(value))
    
    return strings

def main():
    directory = r"E:\Edge下载\Downloads"
    latest = get_latest_cbor(directory)
    
    if not latest:
        print("未找到 .cbor 文件")
        return
    
    print(f"文件: {os.path.basename(latest)}")
    print("-" * 50)
    
    with open(latest, 'rb') as f:
        data = cbor2.load(f)
    
    # 提取所有 UTF-8 字符串
    all_strings = extract_strings_from_bytes(data)
    
    # 过滤掉太短或无意义的
    meaningful = [s.strip() for s in all_strings if len(s.strip()) > 3]
    
    print("提取到的有意义的字符串:")
    print("=" * 50)
    for s in meaningful:
        # 去掉多余的空行
        lines = [line.strip() for line in s.split('\n') if line.strip()]
        for line in lines:
            print(f"  {line}")
    
    # 特别提取 MATMUL 相关信息
    print()
    print("MATMUL 相关:")
    print("=" * 50)
    for s in meaningful:
        if 'MATMUL' in s:
            print(f"  {s}")

if __name__ == "__main__":
    main()