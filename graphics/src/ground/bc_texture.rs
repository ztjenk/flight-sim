// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zachary Jenkins

use std::fs::File;
use std::io::{Read, Seek};
use std::path::Path;
use byteorder::{LittleEndian, ReadBytesExt};

use crate::constants_m::{
    DDS_MAGIC, DDS_DDPF_FOURCC as DDPF_FOURCC, DDS_FOURCC_DXT1 as DXT1_FOURCC,
    DDS_FOURCC_DX10 as DX10_FOURCC, DXGI_FORMAT_BC7_UNORM, DXGI_FORMAT_BC7_UNORM_SRGB,
    DDS_DDSD_MIPMAPCOUNT as DDSD_MIPMAPCOUNT,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum BcFormat {
    #[default]
    None,
    Bc1,  // 8 bytes per 4x4 block
    Bc7,  // 16 bytes per 4x4 block
}

#[derive(Debug)]
pub struct DdsData {
    pub format: BcFormat,
    pub width: u32,
    pub height: u32,
    pub data: Vec<u8>,
    pub mip_offsets: Vec<(u64, u32)>,  // (offset, size) for each mip level
}

pub fn load_dds_raw(path: &Path) -> Result<DdsData, String> {
    let mut file = File::open(path)
        .map_err(|e| format!("Cannot open DDS file '{}': {}", path.display(), e))?;

    let magic = file.read_u32::<LittleEndian>()
        .map_err(|e| format!("Failed to read DDS magic: {}", e))?;

    if magic != DDS_MAGIC {
        return Err(format!("Invalid DDS file: {}", path.display()));
    }

    let _header_size = file.read_u32::<LittleEndian>().map_err(|e| e.to_string())?;
    let flags = file.read_u32::<LittleEndian>().map_err(|e| e.to_string())?;
    let height = file.read_u32::<LittleEndian>().map_err(|e| e.to_string())?;
    let width = file.read_u32::<LittleEndian>().map_err(|e| e.to_string())?;
    let _pitch = file.read_u32::<LittleEndian>().map_err(|e| e.to_string())?;
    let _depth = file.read_u32::<LittleEndian>().map_err(|e| e.to_string())?;
    let mut mip_count = file.read_u32::<LittleEndian>().map_err(|e| e.to_string())?;

    if flags & DDSD_MIPMAPCOUNT == 0 {
        mip_count = 1;
    }
    if mip_count == 0 {
        mip_count = 1;
    }

    // skip reserved1[11]
    for _ in 0..11 {
        file.read_u32::<LittleEndian>().map_err(|e| e.to_string())?;
    }

    // read pixel format
    let _pf_size = file.read_u32::<LittleEndian>().map_err(|e| e.to_string())?;
    let pf_flags = file.read_u32::<LittleEndian>().map_err(|e| e.to_string())?;

    let mut fourcc_bytes = [0u8; 4];
    file.read_exact(&mut fourcc_bytes).map_err(|e| e.to_string())?;
    let fourcc = u32::from_le_bytes(fourcc_bytes);

    // skip rest of pixel format (5 u32s) and caps (4 u32s) and reserved2
    for _ in 0..10 {
        file.read_u32::<LittleEndian>().map_err(|e| e.to_string())?;
    }

    let format = if pf_flags & DDPF_FOURCC != 0 {
        if fourcc == DXT1_FOURCC {
            BcFormat::Bc1
        } else if fourcc_bytes == DX10_FOURCC {
            // DX10 extended header
            let dxgi_format = file.read_u32::<LittleEndian>().map_err(|e| e.to_string())?;
            let _resource_dimension = file.read_u32::<LittleEndian>().map_err(|e| e.to_string())?;
            let _misc_flag = file.read_u32::<LittleEndian>().map_err(|e| e.to_string())?;
            let _array_size = file.read_u32::<LittleEndian>().map_err(|e| e.to_string())?;
            let _misc_flags2 = file.read_u32::<LittleEndian>().map_err(|e| e.to_string())?;

            if dxgi_format == DXGI_FORMAT_BC7_UNORM || dxgi_format == DXGI_FORMAT_BC7_UNORM_SRGB {
                BcFormat::Bc7
            } else {
                return Err(format!("Unsupported DXGI format: {}", dxgi_format));
            }
        } else {
            return Err(format!("Unsupported FourCC: {:?}", fourcc_bytes));
        }
    } else {
        return Err("DDS must use FourCC format".to_string());
    };

    let data_start = file.stream_position().map_err(|e| e.to_string())?;
    let file_size = file.metadata().map_err(|e| e.to_string())?.len();
    let data_size = file_size - data_start;

    let mut data = vec![0u8; data_size as usize];
    file.read_exact(&mut data).map_err(|e| e.to_string())?;

    let block_size: u32 = match format {
        BcFormat::Bc1 => 8,
        BcFormat::Bc7 => 16,
        BcFormat::None => return Err("Unknown format".to_string()),
    };

    // calculate mip level offsets and sizes
    let mut mip_offsets = Vec::with_capacity(mip_count as usize);
    let mut offset: u64 = 0;

    for mip in 0..mip_count {
        let mip_width = (width >> mip).max(1);
        let mip_height = (height >> mip).max(1);
        let blocks_wide = mip_width.div_ceil(4);
        let blocks_high = mip_height.div_ceil(4);
        let mip_size = blocks_wide * blocks_high * block_size;

        mip_offsets.push((offset, mip_size));
        offset += mip_size as u64;
    }

    Ok(DdsData {
        format,
        width,
        height,
        data,
        mip_offsets,
    })
}

// CPU decompression of BC1 data to RGBA (fallback when GPU doesn't support BC)
pub fn decompress_bc1(data: &[u8], width: usize, height: usize) -> Vec<u8> {
    let mut output = vec![0u8; width * height * 4];
    let blocks_x = width.div_ceil(4);
    let blocks_y = height.div_ceil(4);

    for by in 0..blocks_y {
        for bx in 0..blocks_x {
            let block_idx = (by * blocks_x + bx) * 8;
            if block_idx + 8 > data.len() {
                continue;
            }

            let block = &data[block_idx..block_idx + 8];

            // decode two 16-bit RGB565 endpoint colors
            let c0 = u16::from_le_bytes([block[0], block[1]]);
            let c1 = u16::from_le_bytes([block[2], block[3]]);

            let rgb0 = decode_rgb565(c0);
            let rgb1 = decode_rgb565(c1);

            // build 4-color palette based on endpoint ordering
            let colors: [[u8; 4]; 4] = if c0 > c1 {
                // 4-color mode: two interpolated colors
                [
                    [rgb0[0], rgb0[1], rgb0[2], 255],
                    [rgb1[0], rgb1[1], rgb1[2], 255],
                    [
                        ((2 * rgb0[0] as u16 + rgb1[0] as u16) / 3) as u8,
                        ((2 * rgb0[1] as u16 + rgb1[1] as u16) / 3) as u8,
                        ((2 * rgb0[2] as u16 + rgb1[2] as u16) / 3) as u8,
                        255,
                    ],
                    [
                        ((rgb0[0] as u16 + 2 * rgb1[0] as u16) / 3) as u8,
                        ((rgb0[1] as u16 + 2 * rgb1[1] as u16) / 3) as u8,
                        ((rgb0[2] as u16 + 2 * rgb1[2] as u16) / 3) as u8,
                        255,
                    ],
                ]
            } else {
                // 3-color mode with transparent black
                [
                    [rgb0[0], rgb0[1], rgb0[2], 255],
                    [rgb1[0], rgb1[1], rgb1[2], 255],
                    [
                        ((rgb0[0] as u16 + rgb1[0] as u16) / 2) as u8,
                        ((rgb0[1] as u16 + rgb1[1] as u16) / 2) as u8,
                        ((rgb0[2] as u16 + rgb1[2] as u16) / 2) as u8,
                        255,
                    ],
                    [0, 0, 0, 255],
                ]
            };

            // 32 bits of 2-bit indices (16 pixels)
            let indices = u32::from_le_bytes([block[4], block[5], block[6], block[7]]);

            for py in 0..4 {
                let y = by * 4 + py;
                if y >= height {
                    break;
                }

                for px in 0..4 {
                    let x = bx * 4 + px;
                    if x >= width {
                        break;
                    }

                    let bit_pos = (py * 4 + px) * 2;
                    let idx = ((indices >> bit_pos) & 0x3) as usize;
                    let dst = (y * width + x) * 4;

                    output[dst] = colors[idx][0];
                    output[dst + 1] = colors[idx][1];
                    output[dst + 2] = colors[idx][2];
                    output[dst + 3] = colors[idx][3];
                }
            }
        }
    }

    output
}

// decode RGB565 packed color to RGB888
#[inline]
fn decode_rgb565(c: u16) -> [u8; 3] {
    let r = ((c >> 11) & 0x1F) as u8;
    let g = ((c >> 5) & 0x3F) as u8;
    let b = (c & 0x1F) as u8;

    // expand 5/6 bit channels to 8 bit by replicating high bits into low bits
    [
        (r << 3) | (r >> 2),
        (g << 2) | (g >> 4),
        (b << 3) | (b >> 2),
    ]
}