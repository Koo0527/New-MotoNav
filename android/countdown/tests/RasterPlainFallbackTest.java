package com.yuminaga.motonav;

import java.util.Arrays;

/** A receiver without ZMAP must get ordinary RLE, even with a confirmed reference. */
public final class RasterPlainFallbackTest {
    private static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        // 4x4, 2m pixels; a single sixteen-pixel roof run.
        byte[] roofs = {1,0,0,0,0,0,0,0,0,0,4,0,4,0,(byte)0xd0,0x47,(byte)0xf4,0};
        byte[] original = roofs.clone();
        byte[] plain = roofs.clone(); plain[15]=7; plain[16]=(byte)0xf0;
        check(Arrays.equals(RasterPacket.forWire(roofs,plain,true,false),roofs));
        check(Arrays.equals(RasterPacket.forWire(roofs,roofs,true,false),roofs));
        check(Arrays.equals(RasterPacket.forWire(roofs,roofs,false,false),plain));
        check(Arrays.equals(RasterPacket.forWire(plain,roofs,true,false),plain));
        check(Arrays.equals(roofs,original));
        check(RasterPacket.forWire(null,roofs,true,false)==null);
        System.out.println("PASS no-ZMAP fallback: full RLE with/without roof capability; confirmed reference cannot enable delta");
    }
}
