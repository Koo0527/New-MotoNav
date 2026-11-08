#pragma once
#include <zlib.h>
static bool edgeInflate(const uint8_t *source,size_t sourceBytes,uint8_t *destination,size_t exactBytes) {
 z_stream stream={};stream.next_in=const_cast<Bytef *>(source);stream.avail_in=uInt(sourceBytes);
 stream.next_out=destination;stream.avail_out=uInt(exactBytes);
 if(inflateInit(&stream)!=Z_OK)return false;
 const int status=inflate(&stream,Z_FINISH);
 const bool valid=status==Z_STREAM_END && stream.total_in==sourceBytes && stream.total_out==exactBytes;
 inflateEnd(&stream);return valid;
}
