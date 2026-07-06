import cbor2
import os
import glob
import re
from datetime import datetime

def get_latest_cbor(directory):
    """获取最新的 .cbor 文件"""
    pattern = os.path.join(directory, "*.cbor")
    files = glob.glob(pattern)
    if not files:
        return None
    return max(files, key=os.path.getmtime)

def extract_matmul_strings(filepath):
    """提取 MATMUL 相关的字符串"""
    with open(filepath, 'rb') as f:
        data = cbor2.load(f)
    
    def find_matmul(obj):
        results = []
        if isinstance(obj, bytes):
            try:
                decoded = obj.decode('utf-8')
                # 包含 MATMUL 或参数行
                if 'MATMUL' in decoded.upper() or re.search(r'[A-Z]=[0-9A-F]+', decoded):
                    results.append(decoded.strip())
            except:
                pass
        elif isinstance(obj, list):
            for item in obj:
                results.extend(find_matmul(item))
        elif isinstance(obj, dict):
            for value in obj.values():
                results.extend(find_matmul(value))
        return results
    
    return find_matmul(data)

def parse_all_params(text):
    """解析所有 A=XXXXX 格式的参数"""
    data = {}
    
    # 匹配所有 大写字母=十六进制数 的模式
    # 支持 X=XXXXX 以及 X=XXXXX.XXXXX 格式（多点分隔）
    pattern = r'([A-Z])=([0-9A-F\.]+)'
    matches = re.findall(pattern, text, re.IGNORECASE)
    
    for key, value in matches:
        key = key.upper()
        # 处理可能的多点分隔值
        if '.' in value:
            parts = value.split('.')
            values = []
            for p in parts:
                if p.strip():
                    try:
                        values.append(int(p.strip(), 16))
                    except:
                        pass
            if values:
                data[key] = values if len(values) > 1 else values[0]
        else:
            try:
                data[key] = int(value, 16)
            except:
                pass
    
    # 查找 CRC32
    crc_match = re.search(r'MATMUL_CRC32=\s*([0-9A-F]+)', text, re.IGNORECASE)
    if crc_match:
        data['CRC32'] = crc_match.group(1)
    
    return data

def format_time_table(data):
    """生成时间表格"""
    print()
    print("=" * 80)
    print("MATMUL 参数时间分析")
    print("=" * 80)
    print()
    
    # 收集所有参数（排除 CRC32）
    params = {k: v for k, v in data.items() if k != 'CRC32'}
    
    if not params:
        print("未找到参数数据")
        return
    
    # 打印表头
    print(f"{'参数':<6} {'十六进制':<16} {'十进制':<14} {'时间 (20ns)':<18} {'时间 (ms)':<14}")
    print("-" * 80)
    
    # 遍历所有参数
    for key in sorted(params.keys()):
        value = params[key]
        
        # 处理列表（多个值）
        if isinstance(value, list):
            for i, v in enumerate(value):
                label = f"{key}{i+1}" if i > 0 else key
                ns = v * 20
                ms = ns / 1_000_000
                hex_str = f"0x{v:08X}"
                print(f"{label:<6} {hex_str:<16} {v:<14,} {ns:<18,} {ms:<14.6f}")
        else:
            ns = value * 20
            ms = ns / 1_000_000
            hex_str = f"0x{value:08X}"
            print(f"{key:<6} {hex_str:<16} {value:<14,} {ns:<18,} {ms:<14.6f}")
    
    print("-" * 80)
    
    # 计算差值（如果有多个参数）
    print()
    print("参数差值分析:")
    print("-" * 60)
    
    # 获取所有单值参数（非列表）
    single_params = {k: v for k, v in params.items() if not isinstance(v, list)}
    keys = sorted(single_params.keys())
    
    for i in range(len(keys)):
        for j in range(i + 1, len(keys)):
            k1, k2 = keys[i], keys[j]
            v1, v2 = single_params[k1], single_params[k2]
            diff = v2 - v1
            ns = diff * 20
            ms = ns / 1_000_000
            print(f"  {k2} - {k1} = {diff:,} (0x{diff:X}) = {ns:,} ns = {ms:.6f} ms")
    
    # CRC32
    if 'CRC32' in data:
        print()
        print(f"CRC32: {data['CRC32']}")

def main():
    directory = r"E:\Edge下载\Downloads"
    latest = get_latest_cbor(directory)
    
    if not latest:
        print("未找到 .cbor 文件")
        return
    
    print(f"文件: {os.path.basename(latest)}")
    print(f"时间: {datetime.fromtimestamp(os.path.getmtime(latest)).strftime('%Y-%m-%d %H:%M:%S')}")
    print("-" * 80)
    
    # 提取 MATMUL 字符串
    strings = extract_matmul_strings(latest)
    
    # 只取最新的 MATMUL_DONE 相关数据
    last_matmul = []
    found_done = False
    for s in reversed(strings):
        if 'MATMUL_DONE' in s.upper():
            found_done = True
            last_matmul.append(s)
        elif found_done and 'MATMUL_START' in s.upper():
            last_matmul.append(s)
            break
        elif found_done:
            last_matmul.append(s)
    
    last_matmul.reverse()
    
    if not last_matmul:
        print("未找到 MATMUL 数据")
        return
    
    print("最新的 MATMUL 数据:")
    print("-" * 60)
    all_text = ""
    for s in last_matmul:
        print(s)
        all_text += s + "\n"
    
    # 解析所有参数
    data = parse_all_params(all_text)
    
    print()
    print(f"解析到的参数: {', '.join([k for k in data.keys() if k != 'CRC32'])}")
    
    # 显示时间表格
    format_time_table(data)

if __name__ == "__main__":
    main()