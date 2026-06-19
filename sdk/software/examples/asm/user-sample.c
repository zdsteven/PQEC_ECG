// =============================================================================
//  集成电路创新创业大赛 - 龙芯中科杯 区域赛决赛
//  矩阵乘法驱动与校验程序
// =============================================================================
// 任务：
//   1. 从 ExtRAM 读取 5000 组 4x4 无符号矩阵乘法输入数据
//   2. 驱动 RTL 矩阵乘法模块完成全部计算
//   3. 将结果按规定格式写入 ExtRAM 结果区
//   4. 计算 CRC32 校验值
//   5. 通过串口输出 MATMUL_START、CRC32、MATMUL_DONE
// =============================================================================

#include <stdio.h>
#include "matmul.h"
#include "confreg_time.h"
#include "core_time.h"

// 必需的全局变量
unsigned long UART_BASE = 0xbf000000;
unsigned long CONFREG_TIMER_BASE = 0xbf20f100;
unsigned long CONFREG_CLOCKS_PER_SEC = 50000000L;
unsigned long CORE_CLOCKS_PER_SEC = 33000000L;

#ifndef MATMUL_GROUP_NUM
#define MATMUL_GROUP_NUM 5000
#endif

// =============================================================================
//  数据布局常量
// =============================================================================
// ExtRAM 基地址（uncached 映射）
#define EXTRAM_BASE       0x9c400000

// 输入区：从 ExtRAM 偏移 0 开始
// 每组 128 字节（A[16] + B[16]，各 64 字节）
#define INPUT_OFFSET      0x00000000
#define GROUP_INPUT_SIZE  128

// 结果区：紧随输入区
// 每组 192 字节（16 个元素 × 3 word × 4 字节）
#define RESULT_OFFSET     0x0009c400
#define GROUP_RESULT_SIZE 192

// 矩阵乘法器寄存器地址（0xbf50_0000 + 偏移）
#define MATMUL_BASE       0xbf500000
#define MATMUL_CTRL       (MATMUL_BASE + 0x00)
#define MATMUL_STATUS     (MATMUL_BASE + 0x04)
#define MATMUL_A_DATA     (MATMUL_BASE + 0x20)
#define MATMUL_B_DATA     (MATMUL_BASE + 0x60)
#define MATMUL_C_DATA     (MATMUL_BASE + 0xA0)

// =============================================================================
//  CRC32 查找表（标准 IEEE CRC-32 / 多项式 0xEDB88320）
// =============================================================================
static const unsigned int crc32_table[256] = {
    0x00000000, 0x77073096, 0xEE0E612C, 0x990951BA,
    0x076DC419, 0x706AF48F, 0xE963A535, 0x9E6495A3,
    0x0EDB8832, 0x79DCB8A4, 0xE0D5E91B, 0x97D2D988,
    0x09B64C2B, 0x7EB17CBF, 0xE7B82D09, 0x90BF1D9F,
    0x1DB71064, 0x6AB020F2, 0xF3B97148, 0x84BE41DE,
    0x1ADAD47D, 0x6DDDE4EB, 0xF4D4B551, 0x83D385C7,
    0x136C9856, 0x646BA8C0, 0xFD62F97A, 0x8A65C9EC,
    0x14015C4F, 0x63066CD9, 0xFA0F3D63, 0x8D080DF5,
    0x3B6E20C8, 0x4C69105E, 0xD56041E4, 0xA2677172,
    0x3C03E4D1, 0x4B04D447, 0xD20D85FD, 0xA50AB56B,
    0x35B5A8FA, 0x42B2986C, 0xDBBBC9D6, 0xACBCF940,
    0x32D86CE3, 0x45DF5C75, 0xDCD60DCF, 0xABD13D59,
    0x26D930AC, 0x51DE003A, 0xC8D75180, 0xBFD06116,
    0x21B4F6B5, 0x56B3C423, 0xCFBA9599, 0xB8BDA50F,
    0x2802B89E, 0x5F058808, 0xC60CD9B2, 0xB10BE924,
    0x2F6F7C87, 0x58684C11, 0xC1611DAB, 0xB6662D3D,
    0x76DC4190, 0x01DB7106, 0x98D220BC, 0xEFD5102A,
    0x71B18589, 0x06B6B51F, 0x9FBFE4A5, 0xE8B8D433,
    0x7807C9A2, 0x0F00F934, 0x9609A88E, 0xE10E9818,
    0x7F6A0D6B, 0x086D3D2D, 0x91646C97, 0xE6635C01,
    0x6B6B51F4, 0x1C6C6162, 0x856530D8, 0xF262004E,
    0x6C0695ED, 0x1B01A57B, 0x8208F4C1, 0xF50FC457,
    0x65B0D9C6, 0x12B7E950, 0x8ABEE5FE, 0xFDBE9478,
    0x63B2E1DB, 0x14B5D14D, 0x8DBCE0F7, 0xFABD1161,
    0x3C8370D0, 0x4B844046, 0xD28D11FC, 0xA58A216A,
    0x3BEEB4C9, 0x4CE9845F, 0xD5E0D5E5, 0xA2E7E573,
    0x3248DAE2, 0x454FEA74, 0xDC46BBCA, 0xAB418B5C,
    0x35251EFF, 0x42222E69, 0xDB2B7FD3, 0xAC2C4F45,
    0x25E4C8B0, 0x52E3F826, 0xCBEAA99C, 0xBCED990A,
    0x22890CA9, 0x558E3C3F, 0xCC876D85, 0xBB805D13,
    0x2B1F4082, 0x5C187014, 0xC51121AE, 0xB2161138,
    0x2C72849B, 0x5B75B40D, 0xC27CE5B7, 0xB57BD521,
    0x24D4D330, 0x53D3E3A6, 0xCADAB21C, 0xBDDD828A,
    0x23991729, 0x549E27BF, 0xCDF76905, 0xBAF05993,
    0x2A6F4402, 0x5D687494, 0xC461252E, 0xB36615B8,
    0x2D02801B, 0x5A05B08D, 0xC30CE137, 0xB40BD1A1,
    0x3D014614, 0x4A067682, 0xD30F2738, 0xA40817AE,
    0x3A6C820D, 0x4D6BB29B, 0xD462E321, 0xA365D3B7,
    0x33FACE26, 0x44FDDEB0, 0xDDF48F0A, 0xAAF3BF9C,
    0x34972A3F, 0x43901AA9, 0xDA994B13, 0xAD9E7B85,
    0x405C3FF8, 0x375B0F6E, 0xAE525ED4, 0xD9556E42,
    0x4731FBE1, 0x3036CB77, 0xA93F9ACD, 0xDE38AA5B,
    0x4EA719CA, 0x39A0295C, 0xA0A978E6, 0xD7AE4870,
    0x49CADD13, 0x3ECD0D85, 0xA7C4343F, 0xD0C304A9,
    0x596B135C, 0x2E6C23CA, 0xB7657270, 0xC06242E6,
    0x5E06D745, 0x2901E7D3, 0xB008B669, 0xC70F86FF,
    0x5790936E, 0x2097A3F8, 0xB99EF242, 0xCE99C2D4,
    0x50FD5777, 0x27FA67E1, 0xBEF3365B, 0xC9F406CD,
    0x1BB0EB78, 0x6CB7DBEE, 0xF5BE8A54, 0x82B99AC2,
    0x1CDD0F61, 0x6BDA3FF7, 0xF2D36E4D, 0x85D45EDB,
    0x154B434A, 0x624C73DC, 0xFB452266, 0x8C4212F0,
    0x12268753, 0x6521B7C5, 0xFC28E67F, 0x8B2FD6E9,
    0x0CC3D11C, 0x7BC4E18A, 0xE2CDB030, 0x95CAA0A6,
    0x0BAE3505, 0x7CA90593, 0xE5A05429, 0x92A764BF,
    0x0238792E, 0x753F49B8, 0xEC361802, 0x9B312894,
    0x0555BD37, 0x72528DA1, 0xEB5BDC1B, 0x9C5CEC8D,
    0x7DBD4AB0, 0x0ABA7A26, 0x93B32B9C, 0xE4B41B0A,
    0x7AD08EA9, 0x0DD7BE3F, 0x94DEEF85, 0xE3D9DF13,
    0x7346C282, 0x0441F214, 0x9D48A3AE, 0xEA4F9338,
    0x742B069B, 0x032C360D, 0x9A2567B7, 0xED225721,
    0x642A60D4, 0x132D5042, 0x8A2401F8, 0xFD23316E,
    0x6347A4CD, 0x1440945B, 0x8D49C5E1, 0xFA4EF577,
    0x6AD1E8E6, 0x1DD6D870, 0x84DF89CA, 0xF3D8B95C,
    0x6DBC2CFF, 0x1ABD1C69, 0x83B44DD3, 0xF4B37D45,
    0x6DB38AB8, 0x1AB4BA2E, 0x83BDEB94, 0xF4BADB02,
    0x6ADE4EA1, 0x1DD97E37, 0x84D02F8D, 0xF3D71F1B,
    0x6328028A, 0x142F321C, 0x8D2663A6, 0xFA215330,
    0x6445C693, 0x1342F605, 0x8A4BA7BF, 0xFD4C9729,
    0x6484B0DC, 0x1383804A, 0x8A8AD1F0, 0xFD8DE166,
    0x63E974C5, 0x14EE4453, 0x8DE715E9, 0xFAE0257F,
    0x6A7F38EE, 0x1D780878, 0x847159C2, 0xF3766954,
    0x6D12FCF7, 0x1A15CC61, 0x831C9DDB, 0xF41BAD4D,
    0x6C03BABB, 0x1B048A2D, 0x820DDB97, 0xF50AEB01,
    0x6B6E7EA2, 0x1C694E34, 0x85601F8E, 0xF2672F18,
    0x62D83289, 0x15DF021F, 0x8CD653A5, 0xFBD16333,
    0x65B5F690, 0x12B2C606, 0x8BBB97BC, 0xFCBCE72A,
    0x3B32C030, 0x4C35F0A6, 0xD53CA11C, 0xA23B918A,
    0x3C5F0429, 0x4B5834BF, 0xD2516505, 0xA5565593,
    0x35C94802, 0x42CE7894, 0xDBC7292E, 0xACC019B8,
    0x32A48C1B, 0x45A3BC8D, 0xDCAAED37, 0xABADDDA1,
    0x3207B854, 0x450088C2, 0xDC09D978, 0xAB0EE9EE,
    0x356A7C4D, 0x426D4CDB, 0xDB641D61, 0xAC632DF7,
    0x3CFC3066, 0x4BFB00F0, 0xD2F2514A, 0xA5F561DC,
    0x3B91F47F, 0x4C96C4E9, 0xD59F9553, 0xA298A5C5,
    0x2B96E230, 0x5C91D2A6, 0xC598831C, 0xB29FB38A,
    0x2CFB2629, 0x5BFC16BF, 0xC2F54705, 0xB5F27793,
    0x256D6A02, 0x526A5A94, 0xCB630B2E, 0xBC643BB8,
    0x2200AE1B, 0x55079E8D, 0xCC0ECF37, 0xBB09FFA1,
    0x45C49B10, 0x32C3AB86, 0xABC4FA3C, 0xDCC3CAAA,
    0x42A75F09, 0x35A06F9F, 0xACA93E25, 0xDBAE0EB3,
    0x4B311322, 0x3C3623B4, 0xA53F720E, 0xD2384298,
    0x4C5CD73B, 0x3B5BE7AD, 0xA252B617, 0xD5558681,
    0x6CBD9174, 0x1BBAA1E2, 0x82B3F058, 0xF5B4C0CE,
    0x6BD0556D, 0x1CD765FB, 0x85DE3441, 0xF2D904D7,
    0x62461946, 0x154129D0, 0x8C48786A, 0xFB4F48FC,
    0x652BDD5F, 0x122CEDC9, 0x8B25BC73, 0xFC228CE5,
    0x266AC5B0, 0x516DF526, 0xC864A49C, 0xBF63940A,
    0x210701A9, 0x5600313F, 0xCF096085, 0xB80E5013,
    0x28914D82, 0x5F967D14, 0xC69F2CAE, 0xB1981C38,
    0x2FFC899B, 0x58FBB90D, 0xC1F2E8B7, 0xB6F5D821,
    0x12367B90, 0x65314B06, 0xFC381ABC, 0x8B3F2A2A,
    0x155BBF89, 0x625C8F1F, 0xFB55DEA5, 0x8C52EE33,
    0x1CCDF3A2, 0x6BCAC334, 0xF2C3928E, 0x85C4A218,
    0x1BA037BB, 0x6CA7072D, 0xF5AE5697, 0x82A96601,
    0x964D63B4, 0xE14A5322, 0x78430298, 0x0F44320E,
    0x9120A7AD, 0xE627973B, 0x7F2EC681, 0x0829F617,
    0x98B6EB86, 0xEFB1DB10, 0x76B88AAA, 0x01BFFA3C,
    0x9FDB6F9F, 0xE8DC5F09, 0x71D50EB3, 0x06D23E25,
    0x6DB55BD0, 0x1AB26B46, 0x83BB3AFC, 0xF4BC0A6A,
    0x6AD89FC9, 0x1DDFAF5F, 0x84D6FEE5, 0xF3D1CE73,
    0x634ED3E2, 0x1449E374, 0x8D40B2CE, 0xFA478258,
    0x642317FB, 0x1324276D, 0x8A2D76D7, 0xFD2A4641,
    0x13A61310, 0x64A12386, 0xFDA8723C, 0x8AAF42AA,
    0x14CBD709, 0x63CCE79F, 0xFAC5B625, 0x8DC286B3,
    0x1D5D9B22, 0x6A5AABB4, 0xF353FA0E, 0x8454CA98,
    0x1A305F3B, 0x6D376FAD, 0xF43E3E17, 0x83390E81,
    0x3AB12D74, 0x4DB61DE2, 0xD4BF4C58, 0xA3B87CCE,
    0x3DDCE96D, 0x4ADBD9FB, 0xD3D28841, 0xA4D5B8D7,
    0x344AA546, 0x434D95D0, 0xDA44C46A, 0xAD43F4FC,
    0x3327615F, 0x442051C9, 0xDD290073, 0xAA2E30E5,
    0x54620710, 0x23653786, 0xBA6C663C, 0xCD6B56AA,
    0x530FC309, 0x2408F39F, 0xBD01A225, 0xCA0692B3,
    0x5A998F22, 0x2D9EBFB4, 0xB497EE0E, 0xC390DE98,
    0x5DF44B3B, 0x2AF37BAD, 0xB3FA2A17, 0xC4FD1A81,
    0x96511D30, 0xE1562DA6, 0x785F7C1C, 0x0F584C8A,
    0x913CD929, 0xE63BE9BF, 0x7F32B805, 0x08358893,
    0x98AA9502, 0xEFADA594, 0x76A4F42E, 0x01A3C4B8,
    0x9FC7511B, 0xE8C0618D, 0x71C93037, 0x06CE00A1,
    0x8C6D1B54, 0xFB6A2BC2, 0x62637A78, 0x15644AEE,
    0x8B00DF4D, 0xFC07EFDB, 0x650EBE61, 0x12098EF7,
    0x82969366, 0xF591A3F0, 0x6C98F24A, 0x1B9FC2DC,
    0x85FB577F, 0xF2FC67E9, 0x6BF53653, 0x1CF206C5
};

// =============================================================================
//  CRC32 计算函数
// =============================================================================
unsigned int crc32(const unsigned char *data, unsigned int len)
{
    unsigned int crc = 0xFFFFFFFF;
    unsigned int i;
    for (i = 0; i < len; i++) {
        crc = crc32_table[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFF;
}

// =============================================================================
//  矩阵乘法驱动函数
// =============================================================================
// 将 A/B 矩阵写入硬件寄存器，启动计算，等待完成，读取结果
void matmul_compute(volatile unsigned int *a, volatile unsigned int *b,
                    volatile unsigned int *c_out)
{
    volatile unsigned int *reg;
    int i;

    // 写入矩阵 A（16 个元素）
    reg = (volatile unsigned int *)MATMUL_A_DATA;
    for (i = 0; i < 16; i++) {
        reg[i] = a[i];
    }

    // 写入矩阵 B（16 个元素）
    reg = (volatile unsigned int *)MATMUL_B_DATA;
    for (i = 0; i < 16; i++) {
        reg[i] = b[i];
    }

    // 启动计算
    *((volatile unsigned int *)MATMUL_CTRL) = 1;

    // 轮询等待完成
    while (!(*((volatile unsigned int *)MATMUL_STATUS) & 0x2))
        ;

    // 读取结果 C（每个元素 3 个 word：低32、中32、高2）
    reg = (volatile unsigned int *)MATMUL_C_DATA;
    for (i = 0; i < 48; i++) {
        c_out[i] = reg[i];
    }
}

// =============================================================================
//  主函数
// =============================================================================
int main(int argc, char **argv)
{
    volatile unsigned int *input_base  = (volatile unsigned int *)(EXTRAM_BASE + INPUT_OFFSET);
    volatile unsigned int *result_base = (volatile unsigned int *)(EXTRAM_BASE + RESULT_OFFSET);
    unsigned int c_words[48];
    unsigned int g, i;
    unsigned int *p;
    unsigned int crc_val;
    unsigned int start_time, end_time;

    // 输出开始标识
    printf("MATMUL_START\n");

    start_time = get_clock_count();

    // 主循环：处理每组矩阵乘法
    for (g = 0; g < MATMUL_GROUP_NUM; g++) {
        // 当前组的输入地址：input_base + g * 32（32 个 uint32 = 128 字节）
        volatile unsigned int *a_ptr = input_base + g * 32;
        volatile unsigned int *b_ptr = input_base + g * 32 + 16;

        // 驱动硬件计算
        matmul_compute(a_ptr, b_ptr, c_words);

        // 将结果写入 ExtRAM 结果区
        // 当前组的结果地址：result_base + g * 48（48 个 uint32 = 192 字节）
        volatile unsigned int *dst = result_base + g * 48;
        for (i = 0; i < 48; i++) {
            dst[i] = c_words[i];
        }
    }

    end_time = get_clock_count();

    // 计算结果区 CRC32
    // 结果区起始：EXTRAM_BASE + RESULT_OFFSET
    // 结果区长度：MATMUL_GROUP_NUM * 192 字节
    p = (unsigned int *)(EXTRAM_BASE + RESULT_OFFSET);
    crc_val = crc32((const unsigned char *)p, MATMUL_GROUP_NUM * 192);

    // 输出 CRC32 校验结果
    printf("MATMUL_CRC32=%08x\n", crc_val);

    // 输出结束标识
    printf("MATMUL_DONE\n");

    return 0;
}
