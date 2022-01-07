//
//  MGLRenderer.m
//  mgl
//
//  Created by Michael Larson on 11/8/21.
//

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

@import simd;
@import MetalKit;

#include <mach/mach_vm.h>
#include <mach/mach_init.h>
#include <mach/vm_map.h>

// Header shared between C code here, which executes Metal API commands, and .metal files, which
// uses these types as inputs to the shaders.
//#import "AAPLShaderTypes.h"

#import "MGLRenderer.h"

#import "glm_context.h"

extern void mglDrawBuffer(GLMContext ctx, GLenum buf);

// for resource types SPVC_RESOURCE_TYPE_UNIFORM_BUFFER..
#import "spirv_cross_c.h"

typedef struct SyncList_t {
    GLuint count;
    GLuint  size;
    Sync **list;
} SyncList;

MTLPixelFormat mtlPixelFormatForGLTex(Texture * gl_tex);

typedef struct MGLDrawable_t {
    GLuint width;
    GLuint height;
    id<MTLTexture> drawbuffer;
    id<MTLTexture> depthbuffer;
    id<MTLTexture> stencilbuffer;
} MGLDrawable;

enum {
    _FRONT,
    _BACK,
    _FRONT_LEFT,
    _FRONT_RIGHT,
    _BACK_LEFT,
    _BACK_RIGHT,
    _MAX_DRAW_BUFFERS
};

// Main class performing the rendering
@implementation MGLRenderer
{
    NSView *_view;

    CAMetalLayer *_layer;
    id<CAMetalDrawable> _drawable;

    GLMContext  ctx;    // context macros need this exact name

    id<MTLDevice> _device;

    MGLDrawable _drawBuffers[_MAX_DRAW_BUFFERS];

    MTLBlendFactor _src_blend_rgb_factor[MAX_COLOR_ATTACHMENTS];
    MTLBlendFactor _dst_blend_rgb_factor[MAX_COLOR_ATTACHMENTS];
    MTLBlendFactor _src_blend_alpha_factor[MAX_COLOR_ATTACHMENTS];
    MTLBlendFactor _dst_blend_alpha_factor[MAX_COLOR_ATTACHMENTS];
    MTLBlendOperation _rgb_blend_operation[MAX_COLOR_ATTACHMENTS];
    MTLBlendOperation _alpha_blend_operation[MAX_COLOR_ATTACHMENTS];
    MTLColorWriteMask _color_mask[MAX_COLOR_ATTACHMENTS];

    // The command queue used to pass commands to the device.
    id<MTLCommandQueue> _commandQueue;

    // The render pipeline generated from the vertex and fragment shaders in the .metal shader file.
    id<MTLRenderPipelineState> _pipelineState;

    // render pass descriptor containts the binding information for VAO's and such
    MTLRenderPassDescriptor *_renderPassDescriptor;

    // each pass a new command buffer is created
    id<MTLCommandBuffer> _currentCommandBuffer;
    SyncList  *_currentCommandBufferSyncList;

    id<MTLRenderCommandEncoder> _currentRenderEncoder;

    id<MTLBlitCommandEncoder> _currentBlitEncoder;

    id<MTLEvent> _currentEvent;
    GLsizei _currentSyncName;
}

MTLVertexFormat glTypeSizeToMtlType(GLuint type, GLuint size, bool normalized)
{
    switch(type)
    {
        case GL_UNSIGNED_BYTE:
            if (normalized)
            {
                switch(size)
                {
                    case 1: return MTLVertexFormatUCharNormalized;
                    case 2: return MTLVertexFormatUChar2Normalized;
                    case 3: return MTLVertexFormatUChar3Normalized;
                    case 4: return MTLVertexFormatUChar4Normalized;
                }
            }
            else
            {
                switch(size)
                {
                    case 1: return MTLVertexFormatUChar;
                    case 2: return MTLVertexFormatUChar2;
                    case 3: return MTLVertexFormatUChar3;
                    case 4: return MTLVertexFormatUChar4;
                }
            }
            break;

        case GL_BYTE:
            if (normalized)
            {
                switch(size)
                {
                    case 1: return MTLVertexFormatCharNormalized;
                    case 2: return MTLVertexFormatChar2Normalized;
                    case 3: return MTLVertexFormatChar3Normalized;
                    case 4: return MTLVertexFormatChar4Normalized;
                }
            }
            else
            {
                switch(size)
                {
                    case 1: return MTLVertexFormatChar;
                    case 2: return MTLVertexFormatChar2;
                    case 3: return MTLVertexFormatChar3;
                    case 4: return MTLVertexFormatChar4;
                }
            }
            break;

        case GL_UNSIGNED_SHORT:
            if (normalized)
            {
                switch(size)
                {
                    case 1: return MTLVertexFormatUShortNormalized;
                    case 2: return MTLVertexFormatUShort2Normalized;
                    case 3: return MTLVertexFormatUShort3Normalized;
                    case 4: return MTLVertexFormatUShort4Normalized;
                }
            }
            else
            {
                switch(size)
                {
                    case 1: return MTLVertexFormatUShort;
                    case 2: return MTLVertexFormatUShort2;
                    case 3: return MTLVertexFormatUShort3;
                    case 4: return MTLVertexFormatUShort4;
                }
            }
            break;

        case GL_SHORT:
            if (normalized)
            {
                switch(size)
                {
                    case 1: return MTLVertexFormatUShortNormalized;
                    case 2: return MTLVertexFormatShort2Normalized;
                    case 3: return MTLVertexFormatShort3Normalized;
                    case 4: return MTLVertexFormatShort4Normalized;
                }
            }
            else
            {
                switch(size)
                {
                    case 1: return MTLVertexFormatUShort;
                    case 2: return MTLVertexFormatShort2;
                    case 3: return MTLVertexFormatShort3;
                    case 4: return MTLVertexFormatShort4;
                }
            }
            break;

            case GL_HALF_FLOAT:
                switch(size)
                {
                    case 1: return MTLVertexFormatHalf;
                    case 2: return MTLVertexFormatHalf2;
                    case 3: return MTLVertexFormatHalf3;
                    case 4: return MTLVertexFormatHalf4;
                }
                break;

            case GL_FLOAT:
                switch(size)
                {
                    case 1: return MTLVertexFormatFloat;
                    case 2: return MTLVertexFormatFloat2;
                    case 3: return MTLVertexFormatFloat3;
                    case 4: return MTLVertexFormatFloat4;
                }
                break;

            case GL_INT:
                switch(size)
                {
                    case 1: return MTLVertexFormatInt;
                    case 2: return MTLVertexFormatInt2;
                    case 3: return MTLVertexFormatInt3;
                    case 4: return MTLVertexFormatInt4;
                }
                break;

            case GL_UNSIGNED_INT:
                switch(size)
                {
                    case 1: return MTLVertexFormatUInt;
                    case 2: return MTLVertexFormatUInt2;
                    case 3: return MTLVertexFormatUInt3;
                    case 4: return MTLVertexFormatUInt4;
                }
                break;

            case GL_RGB10:
                if (normalized)
                    return MTLVertexFormatInt1010102Normalized;
                break;

            case GL_UNSIGNED_INT_10_10_10_2:
                if (normalized)
                    return MTLVertexFormatInt1010102Normalized;
                break;
        }

    return MTLVertexFormatInvalid;
}

#pragma mark buffer objects
- (bool) mapGLBuffersToMTLBufferMap:(BufferMapList *)buffer_map stage: (int) stage
{
    int count;

    buffer_map->count = 0;

    // iterate uniform buffers
    count = [self getProgramBindingCount: stage type: SPVC_RESOURCE_TYPE_UNIFORM_BUFFER];
    if (count)
    {
        int buffers_to_be_mapped = count;

        for (int i=0;
             (buffers_to_be_mapped > 0) && (i < ctx->state.max_vertex_attribs);
             i++)
        {
            GLuint spirv_binding;
            Buffer *ptr;

            // get the ubo binding from spirv
            spirv_binding = [self getProgramBinding:stage type:SPVC_RESOURCE_TYPE_UNIFORM_BUFFER index: i];

            ptr = ctx->state.vao->buffer_base.targets[spirv_binding].buffer;

            if (ptr)
            {
                if (ptr->target == GL_UNIFORM_BUFFER)
                {
                    buffer_map->buffers[i].attribute_mask = 0;
                    buffer_map->buffers[i].buffer_base_index = spirv_binding;
                    buffer_map->buffers[i].buffer = ptr;
                    buffer_map->count++;
                    buffers_to_be_mapped--;
                }
                else
                {
                    assert(0);
                }
            }
            else
            {
                assert(0);
            }
        }
    }

    // iterate shader storage buffers
    count = [self getProgramBindingCount: stage type: SPVC_RESOURCE_TYPE_STORAGE_BUFFER];
    if (count)
    {
        int buffers_to_be_mapped = count;

        for (int i=0;
             (buffers_to_be_mapped > 0) && (i < ctx->state.max_vertex_attribs);
             i++)
        {
            GLuint spirv_binding;
            Buffer *ptr;

            spirv_binding = [self getProgramBinding:stage type:SPVC_RESOURCE_TYPE_STORAGE_BUFFER index: i];
            ptr = ctx->state.vao->buffer_base.targets[spirv_binding].buffer;

            if (ptr)
            {
                if (ptr->target == GL_SHADER_STORAGE_BUFFER)
                {
                    GLuint spirv_binding = [self getProgramBinding:stage type:GL_SHADER_STORAGE_BUFFER index: i];

                    assert(buffer_map->count < ctx->state.max_vertex_attribs);
                    buffer_map->buffers[i].attribute_mask = 0;
                    buffer_map->buffers[i].buffer_base_index = spirv_binding;
                    buffer_map->buffers[i].buffer = ptr;
                    buffer_map->count++;
                }
                else
                {
                    assert(0);
                }
            }
            else
            {
                assert(0);
            }
        }
    }

    // bind vao attribs to buffers (attribs can share the same buffer)
    if (stage == _VERTEX_SHADER)
    {
        int vao_buffer_start;
        int mapped_buffers;

        count = [self getProgramBindingCount: stage type: SPVC_RESOURCE_TYPE_STAGE_INPUT];
        mapped_buffers = 0;

        // vao buffers start after the uniforms and shader buffers
        vao_buffer_start = buffer_map->count;
        assert(buffer_map->count < ctx->state.max_vertex_attribs);
        buffer_map->buffers[vao_buffer_start].buffer = NULL;

        // create attribute map
        for(int att=0;att<ctx->state.max_vertex_attribs; att++)
        {
            if (VAO_STATE(enabled_attribs) & (0x1 << att))
            {
                if (VAO_ATTRIB_STATE(att).buffer == NULL)
                {
                    ctx->error_func(ctx, __FUNCTION__, GL_INVALID_OPERATION);

                    return false;
                }

                // check all the buffers for metal objects
                Buffer *gl_buffer;
                Buffer *map_buffer;

                gl_buffer = VAO_ATTRIB_STATE(att).buffer;
                assert(gl_buffer);

                map_buffer = buffer_map->buffers[vao_buffer_start].buffer;

                if (map_buffer == NULL)
                {
                    // map the buffer object to a metal vertex index
                    assert(buffer_map->count < ctx->state.max_vertex_attribs);
                    buffer_map->buffers[vao_buffer_start].attribute_mask |= (0x1 << att);
                    buffer_map->buffers[vao_buffer_start].buffer = gl_buffer;
                    buffer_map->count++;

                    mapped_buffers++;
                }
                else
                {
                    bool found_buffer = false;

                    for (int map=vao_buffer_start;
                         (found_buffer == false) && map<buffer_map->count;
                         map++)
                    {
                        // we need to check name and target, not pointers..
                        if ((map_buffer->name == gl_buffer->name) &&
                            (map_buffer->target == gl_buffer->target))
                        {
                            // include it the list of attributes
                            buffer_map->buffers[map].attribute_mask |= (0x1 << att);
                            found_buffer = true;
                            break;
                        }
                    }

                    if (found_buffer == false)
                    {
                        // map the next buffer object to a metal vertex index
                        assert(buffer_map->count < ctx->state.max_vertex_attribs);
                        buffer_map->buffers[buffer_map->count].attribute_mask = (0x1 << att);
                        buffer_map->buffers[buffer_map->count].buffer = gl_buffer;
                        buffer_map->count++;

                        mapped_buffers++;
                    }
                }
            }

            if ((VAO_STATE(enabled_attribs) >> (att+1)) == 0)
                break;
        }

        assert(mapped_buffers == count);
    }

    return true;
}

- (bool) mapBuffersToMTL
{
    if ([self mapGLBuffersToMTLBufferMap: &ctx->state.vertex_buffer_map_list stage:_VERTEX_SHADER] == false)
        return false;

    if ([self mapGLBuffersToMTLBufferMap: &ctx->state.fragment_buffer_map_list stage:_FRAGMENT_SHADER] == false)
        return false;

    return true;
}

- (id<MTLBuffer>) createMTLBufferFromGLMBuffer:(Buffer *) ptr
{
    MTLResourceOptions options;

    if (ptr->immutable_storage & BUFFER_IMMUTABLE_STORAGE_FLAG)
    {
        if (ptr->storage_flags & GL_CLIENT_STORAGE_BIT)
        {
            options = MTLResourceCPUCacheModeDefaultCache | MTLResourceStorageModeManaged;

            // ways we will only write to this
            if ((ptr->storage_flags & GL_MAP_READ_BIT) == 0)
            {
                options |= MTLResourceCPUCacheModeWriteCombined;
            }

            id<MTLBuffer> buffer = [_device newBufferWithBytesNoCopy: (void *)(ptr->data.buffer_data)
                                                         length: ptr->data.buffer_size
                                                        options: options
                                                    deallocator: ^(void *pointer, NSUInteger length)
                                                    {
                                                        kern_return_t err;

                                                        err = vm_deallocate((vm_map_t) mach_task_self(),
                                                                            (vm_address_t) pointer,
                                                                            length);

                                                        assert(err == 0);
                                                    }];

            return buffer;
        }
        else
        {
            options = MTLResourceCPUCacheModeDefaultCache;

            // ways we will only write to this
            if ((ptr->storage_flags & GL_MAP_READ_BIT) == 0)
            {
                options |= MTLResourceCPUCacheModeWriteCombined;
            }

            id<MTLBuffer> buffer = [_device newBufferWithLength: ptr->data.buffer_size
                                                        options: options];

            return buffer;
        }
    }
    else // non immutable buffer
    {
        options = MTLResourceCPUCacheModeDefaultCache | MTLResourceStorageModeManaged;

        // ways we will only write to this
        if (ptr->usage == GL_DYNAMIC_DRAW)
        {
            options |= MTLResourceCPUCacheModeWriteCombined;
        }

        id<MTLBuffer> buffer = [_device newBufferWithBytesNoCopy: (void *)(ptr->data.buffer_data)
                                                     length: ptr->data.buffer_size
                                                    options: options
                                                deallocator: ^(void *pointer, NSUInteger length)
                                                {
                                                    kern_return_t err;

                                                    err = vm_deallocate((vm_map_t) mach_task_self(),
                                                                        (vm_address_t) pointer,
                                                                        length);

                                                    assert(err == 0);
                                                }];

        return buffer;
    }

    return NULL;
}

- (bool) updateDirtyBuffer:(Buffer *)ptr
{
    if (ptr->data.dirty_bits & DIRTY_BUFFER_ADDR)
    {
        if (ptr->data.mtl_data == NULL)
        {
            id <MTLBuffer> buffer = [self createMTLBufferFromGLMBuffer: ptr];

            ptr->data.mtl_data = (void *)CFBridgingRetain(buffer);

            assert(ptr->data.mtl_data);

            [buffer didModifyRange: NSMakeRange(0, ptr->data.buffer_size)];

            // clear dirty bits
            ptr->data.dirty_bits = 0;
        }
    }
    else if (ptr->data.dirty_bits & DIRTY_BUFFER_DATA)
    {
        id<MTLBuffer> buffer = (__bridge id<MTLBuffer>)(ptr->data.mtl_data);

        assert(buffer);

        // clear dirty bits if not mapped as coherent
        // this will cause us to keep loading the buffer and keep the GPU
        // contents in check for EVERY drawing operation
        if (ptr->access & GL_MAP_COHERENT_BIT)
        {
            [buffer didModifyRange: NSMakeRange(ptr->mapped_offset, ptr->mapped_length)];

            ptr->data.dirty_bits = DIRTY_BUFFER_DATA;
        }
        else
        {
            [buffer didModifyRange: NSMakeRange(ptr->mapped_offset, ptr->mapped_length)];

            ptr->data.dirty_bits = 0;
        }
    }
    else
    {
        assert(0);
    }

    return true;
}

- (bool) updateDirtyBaseBufferList: (BufferMapList *)buffer_map_list
{
    // update vbos, some vbos may not have metal buffers yet
    for(int i=0;i<buffer_map_list->count; i++)
    {
        Buffer *gl_buffer;

        gl_buffer = buffer_map_list->buffers[i].buffer;

        if (gl_buffer)
        {
            if (gl_buffer->data.dirty_bits)
            {
                [self updateDirtyBuffer: gl_buffer];
            }
        }
    }

    return true;
}

- (bool) bindBuffersToCurrentRenderEncoder
{
    assert(_currentRenderEncoder);

    for(int i=0; i<ctx->state.vertex_buffer_map_list.count; i++)
    {
        Buffer *ptr;

        ptr = ctx->state.vertex_buffer_map_list.buffers[i].buffer;

        assert(ptr);
        assert(ptr->data.mtl_data);

        id<MTLBuffer> buffer = (__bridge id<MTLBuffer>)(ptr->data.mtl_data);
        assert(buffer);

        [_currentRenderEncoder setVertexBuffer:buffer offset:0 atIndex:i ];
    }

    for(int i=0; i<ctx->state.fragment_buffer_map_list.count; i++)
    {
        Buffer *ptr;

        ptr = ctx->state.fragment_buffer_map_list.buffers[i].buffer;

        assert(ptr);
        assert(ptr->data.mtl_data);

        id<MTLBuffer> buffer = (__bridge id<MTLBuffer>)(ptr->data.mtl_data);
        assert(buffer);

        [_currentRenderEncoder setFragmentBuffer:buffer offset:0 atIndex:i ];
    }

    return true;
}

- (bool) bindTexturesToCurrentRenderEncoder
{
    GLuint count;

    // iterate shader storage buffers
    count = [self getProgramBindingCount: _FRAGMENT_SHADER type: SPVC_RESOURCE_TYPE_SAMPLED_IMAGE];
    if (count)
    {
        int textures_to_be_mapped = count;

        assert(textures_to_be_mapped < TEXTURE_UNITS);

        for (int i=0; (i<TEXTURE_UNITS) && (textures_to_be_mapped > 0); i++)
        {
            GLuint spirv_location;
            Texture *ptr;

            spirv_location = [self getProgramLocation:_FRAGMENT_SHADER type:SPVC_RESOURCE_TYPE_SAMPLED_IMAGE index: i];

            ptr = STATE(active_textures[i]);

            if (ptr)
            {
                id<MTLTexture> texture;

                texture = (__bridge id<MTLTexture>)(ptr->mtl_data);
                assert(texture);

                [_currentRenderEncoder setFragmentTexture:texture atIndex:spirv_location];

                textures_to_be_mapped--;

                MTLSamplerDescriptor *samplerDescriptor = [MTLSamplerDescriptor new];
                samplerDescriptor.minFilter = MTLSamplerMinMagFilterNearest;
                samplerDescriptor.magFilter = MTLSamplerMinMagFilterLinear;
                samplerDescriptor.sAddressMode = MTLSamplerAddressModeRepeat;
                samplerDescriptor.tAddressMode = MTLSamplerAddressModeRepeat;

                id<MTLSamplerState> sampler = [_device newSamplerStateWithDescriptor:samplerDescriptor];
                assert(sampler);

                [_currentRenderEncoder setFragmentSamplerState:sampler atIndex:spirv_location];
            }
        }

        // texture not found
        if (textures_to_be_mapped)
        {
            printf("No texture bound for fragment shader location\n");

            return false;
        }
    }

    return true;
}

- (int) getVertexBufferIndexWithAttributeSet: (int) attribute
{
    for(int i=0; i<ctx->state.vertex_buffer_map_list.count; i++)
    {
        if (ctx->state.vertex_buffer_map_list.buffers[i].attribute_mask & (0x1 << attribute))
            return i;
    }

    assert(0);

    return 0;
}

#pragma mark textures

- (id<MTLTexture>) createMTLTextureFromGLTexture:(Texture *) tex
{
    NSUInteger width, height, depth;

    MTLTextureDescriptor *tex_desc;
    MTLTextureType tex_type;
    MTLPixelFormat pixelFormat;
    BOOL mipmapped;

    switch(tex->target)
    {
        case GL_TEXTURE_1D: tex_type = MTLTextureType1D; break;
        // case GL_TEXTURE_1D_ARRAY: tex_type = MTLTextureType1DArray; break;
        case GL_TEXTURE_2D: tex_type = MTLTextureType2D; break;
        // case GL_TEXTURE_2D_ARRAY: tex_type = MTLTextureType2DArray; break;
        // case GL_TEXTURE_2D_MULTISAMPLE: tex_type = MTLTextureType2DMultisample; break;
        // case GL_TEXTURE_CUBE_MAP: tex_type = MTLTextureTypeCube; break;
        // case GL_TEXTURE_CUBE_MAP_ARRAY: tex_type = MTLTextureTypeCubeArray; break;
        // case GL_TEXTURE_3D: tex_type = MTLTextureType2DMultisampleArray; break;
        // case GL_TEXTURE_2D_MULTISAMPLE_ARRAY: tex_type = MTLTextureType2DMultisampleArray; break;
        // case GL_TEXTURE_BUFFER: tex_type = MTLTextureTypeTextureBuffer; break;

        default:
            assert(0);
            break;
    }

    // verify completeness of texture when used
    for (int i=0; i<tex->num_levels; i++)
    {
        // incomplete texture
        if (tex->levels[i].complete == false)
            return NULL;
    }

    if (tex->num_levels > 1)
    {
        if (tex->num_levels != tex->max_levels - 1)
        {
            return NULL;
        }

        tex->mipmapped = true;
    }
    tex->complete = true;


    pixelFormat = mtlPixelFormatForGLTex(tex);
    assert(pixelFormat != MTLPixelFormatInvalid);

    width = tex->width;
    height = tex->height;
    depth = tex->depth;
    mipmapped = tex->mipmapped == 1;

    tex_desc = [[MTLTextureDescriptor alloc] init];
    tex_desc.width = width;
    if (height)
        tex_desc.height = height;
    if (depth)
        tex_desc.depth = depth;

    if (mipmapped)
    {
        tex_desc.mipmapLevelCount = tex->num_levels;
    }

    tex_desc.usage = MTLTextureUsageShaderRead;

    if (tex->is_render_target)
    {
        tex_desc.usage |= MTLTextureUsageRenderTarget;
    }

    assert(tex_desc);

    if ((tex->params.swizzle_r != GL_RED) ||
        (tex->params.swizzle_g != GL_GREEN) ||
        (tex->params.swizzle_b != GL_BLUE) ||
        (tex->params.swizzle_a != GL_ALPHA))
    {
        unsigned param, channel, channel_r, channel_g, channel_b, channel_a;

        param = 0;
        channel_r = channel_g = channel_b = channel_a = 0;

        for(int i=0; i<4; i++)
        {
            switch(i)
            {
                case 0: param = tex->params.swizzle_r; break;
                case 1: param = tex->params.swizzle_g; break;
                case 2: param = tex->params.swizzle_b; break;
                case 3: param = tex->params.swizzle_a; break;
            }

            switch(param)
            {
                case GL_RED: channel = MTLTextureSwizzleRed; break;
                case GL_GREEN: channel = MTLTextureSwizzleGreen; break;
                case GL_BLUE: channel = MTLTextureSwizzleBlue; break;
                case GL_ALPHA: channel = MTLTextureSwizzleAlpha; break;
                default: assert(0); break;
            }

            switch(i)
            {
                case 0: channel_r = channel; break;
                case 1: channel_g = channel; break;
                case 2: channel_b = channel; break;
                case 3: channel_a = channel; break;
            }
        }

        tex_desc.swizzle = MTLTextureSwizzleChannelsMake(channel_r, channel_g, channel_b, channel_a);
    }

    id<MTLTexture> texture = [_device newTextureWithDescriptor:tex_desc];
    assert(texture);

    if (tex->dirty_bits & DIRTY_TEXTURE_DATA)
    {
        MTLRegion region;

        for (int i=0; i<tex->num_levels; i++)
        {
            width = tex->levels[i].width;
            height = tex->levels[i].height;
            depth = tex->levels[i].depth;

            if (depth > 1)
                region = MTLRegionMake3D(0,0,0,width,height,depth);
            else if (height > 1)
                region = MTLRegionMake2D(0,0,width,height);
            else
                region = MTLRegionMake1D(0,width);

            NSUInteger bytesPerRow;
            bytesPerRow = tex->levels[i].pitch;
            assert(bytesPerRow);

            NSUInteger bytesPerImage;
            bytesPerImage = tex->levels[i].data_size;
            assert(bytesPerImage);

            [texture replaceRegion:region mipmapLevel:i slice:0 withBytes:(void *)tex->levels[i].data bytesPerRow:bytesPerRow bytesPerImage:(NSUInteger)bytesPerImage];
        }

        tex->dirty_bits &= ~DIRTY_TEXTURE_DATA;
    }

    return texture;
}

- (id<MTLSamplerState>) createMTLSamplerForTexture:(Texture *)tex
{
    MTLSamplerDescriptor *samplerDescriptor;

    samplerDescriptor = [MTLSamplerDescriptor new];
    assert(samplerDescriptor);

    switch(tex->params.min_filter)
    {
        case GL_NEAREST:
            samplerDescriptor.minFilter = MTLSamplerMinMagFilterNearest;
            break;

        case GL_LINEAR:
            samplerDescriptor.minFilter = MTLSamplerMinMagFilterLinear;
            break;

        case GL_NEAREST_MIPMAP_NEAREST:
            samplerDescriptor.minFilter = MTLSamplerMinMagFilterNearest;
            samplerDescriptor.mipFilter = MTLSamplerMipFilterNearest;
            break;

        case GL_LINEAR_MIPMAP_NEAREST:
            samplerDescriptor.minFilter = MTLSamplerMinMagFilterLinear;
            samplerDescriptor.mipFilter = MTLSamplerMipFilterNearest;
            break;

        case GL_NEAREST_MIPMAP_LINEAR:
            samplerDescriptor.minFilter = MTLSamplerMinMagFilterNearest;
            samplerDescriptor.mipFilter = MTLSamplerMipFilterLinear;
            break;

        case GL_LINEAR_MIPMAP_LINEAR:
            samplerDescriptor.minFilter = MTLSamplerMinMagFilterLinear;
            samplerDescriptor.mipFilter = MTLSamplerMipFilterLinear;
            break;

        default:
            assert(0);
            break;
    }

    switch(tex->params.mag_filter)
    {
        case GL_NEAREST:
            samplerDescriptor.magFilter = MTLSamplerMinMagFilterNearest;
            break;

        case GL_LINEAR:
            samplerDescriptor.magFilter = MTLSamplerMinMagFilterLinear;
            break;

        default:
            assert(0);
            break;
    }

    //     @property (nonatomic) NSUInteger maxAnisotropy;
    if (tex->params.max_anisotropy > 1.0)
    {
        samplerDescriptor.maxAnisotropy = tex->params.max_anisotropy;
    }

    //    @property (nonatomic) MTLSamplerAddressMode sAddressMode;
    //    @property (nonatomic) MTLSamplerAddressMode tAddressMode;
    //    @property (nonatomic) MTLSamplerAddressMode rAddressMode;
    for (int i=0; i<3; i++)
    {
        MTLSamplerAddressMode mode = 0;
        GLenum type = 0;

        switch(i)
        {
            case 0: type = tex->params.wrap_s; break;
            case 1: type = tex->params.wrap_t; break;
            case 2: type = tex->params.wrap_r; break;
        }

        switch(type)
        {
            case GL_CLAMP_TO_EDGE:
                mode = MTLSamplerAddressModeClampToEdge;
                break;

            case GL_CLAMP_TO_BORDER:
                mode = MTLSamplerAddressModeClampToBorderColor;
                break;

            case GL_MIRRORED_REPEAT:
                mode = MTLSamplerAddressModeMirrorRepeat;
                break;

            case GL_REPEAT:
                mode = MTLSamplerAddressModeRepeat;
                break;

            case GL_MIRROR_CLAMP_TO_EDGE:
                mode = MTLSamplerAddressModeMirrorClampToEdge;
                break;

    //        case GL_CLAMP_TO_ZERO_MGL_EXT:
    //            mode = MTLSamplerAddressModeClampToZero;
    //            break;

            default:
                assert(0);
                break;
        }

        switch(i)
        {
            case 0: samplerDescriptor.sAddressMode = mode; break;
            case 1: samplerDescriptor.tAddressMode = mode; break;
            case 2: samplerDescriptor.rAddressMode = mode; break;
        }
    }

    if ((tex->params.border_color[0] == 0.0) &&
        (tex->params.border_color[1] == 0.0) &&
        (tex->params.border_color[2] == 0.0))
    {
        if (tex->params.border_color[3] == 0.0)
        {
            samplerDescriptor.borderColor = MTLSamplerBorderColorTransparentBlack;
        }
        else if (tex->params.border_color[3] == 1.0)
        {
            samplerDescriptor.borderColor = MTLSamplerBorderColorOpaqueBlack;
        }
    }
    else    if ((tex->params.border_color[0] == 1.0) &&
                (tex->params.border_color[1] == 1.0) &&
                (tex->params.border_color[2] == 1.0) &&
                (tex->params.border_color[3] == 1.0))
    {
        samplerDescriptor.borderColor = MTLSamplerBorderColorOpaqueWhite;
    }
    else
    {
        assert(0);
    }

    if (tex->target == GL_TEXTURE_RECTANGLE)
    {
        if ((tex->params.wrap_s == GL_CLAMP_TO_EDGE) &&
            (tex->params.wrap_t == GL_CLAMP_TO_EDGE) &&
            (tex->params.wrap_r == GL_CLAMP_TO_EDGE))
        {
            samplerDescriptor.normalizedCoordinates = false;
        }
        else
        {
            printf("Non-normalized coordinates should only be used with 1D and 2D textures with the ClampToEdge wrap mode, otherwise the results of sampling are undefined.");
        }
    }

    // @property (nonatomic) BOOL lodAverage API_AVAILABLE(ios(9.0), macos(11.0), macCatalyst(14.0));


    // @property (nonatomic) MTLCompareFunction compareFunction API_AVAILABLE(macos(10.11), ios(9.0));
    switch(tex->params.compare_func)
    {
        case GL_LEQUAL:
            samplerDescriptor.compareFunction = MTLCompareFunctionLessEqual;
            break;

        case GL_GEQUAL:
            samplerDescriptor.compareFunction = MTLCompareFunctionGreaterEqual;
            break;

        case GL_LESS:
            samplerDescriptor.compareFunction = MTLCompareFunctionLess;
            break;

        case GL_GREATER:
            samplerDescriptor.compareFunction = MTLCompareFunctionGreater;
            break;

        case GL_EQUAL:
            samplerDescriptor.compareFunction = MTLCompareFunctionEqual;
            break;

        case GL_NOTEQUAL:
            samplerDescriptor.compareFunction = MTLCompareFunctionNotEqual;
            break;

        case GL_ALWAYS:
            samplerDescriptor.compareFunction = MTLCompareFunctionAlways;
            break;

        case GL_NEVER:
            samplerDescriptor.compareFunction = MTLCompareFunctionNever;
            break;

        default:
            assert(0);
            break;
    }

    id<MTLSamplerState> sampler = [_device newSamplerStateWithDescriptor:samplerDescriptor];
    assert(sampler);

    return sampler;
}

- (Texture *)framebufferAttachmentTexture: (FBOAttachment *)fbo_attachment
{
    Texture *tex;

    if (fbo_attachment->textarget == GL_RENDERBUFFER)
    {
        tex = fbo_attachment->buf.rbo->tex;
    }
    else
    {
        tex = fbo_attachment->buf.tex;
    }
    assert(tex);

    return tex;
}

#pragma mark programs
- (int) getProgramBindingCount: (int) stage type: (int) type
{
    Program *ptr;

    assert(stage < _MAX_SPIRV_RES);
    switch(type)
    {
        case SPVC_RESOURCE_TYPE_UNIFORM_BUFFER:
        case SPVC_RESOURCE_TYPE_STORAGE_BUFFER:
        case SPVC_RESOURCE_TYPE_STAGE_INPUT:
        case SPVC_RESOURCE_TYPE_SAMPLED_IMAGE:
            break;

        default:
           assert(0);
    }

    ptr = ctx->state.program;
    assert(ptr);

    return ptr->spirv_resources_list[stage][type].count;
}

- (int) getProgramBinding: (int) stage type: (int) type index: (int) index
{
    Program *ptr;

    assert(stage < _MAX_SPIRV_RES);
    switch(type)
    {
       case SPVC_RESOURCE_TYPE_UNIFORM_BUFFER:
       case SPVC_RESOURCE_TYPE_STORAGE_BUFFER:
       case SPVC_RESOURCE_TYPE_STAGE_INPUT:
       case SPVC_RESOURCE_TYPE_SAMPLED_IMAGE:
           break;

       default:
          assert(0);
    }

    ptr = ctx->state.program;
    assert(ptr);

    assert(index < ptr->spirv_resources_list[stage][type].count);

    return ptr->spirv_resources_list[stage][type].list[index].binding;
}

- (int) getProgramLocation: (int) stage type: (int) type index: (int) index
{
    Program *ptr;

    assert(stage < _MAX_SPIRV_RES);
    switch(type)
    {
       case SPVC_RESOURCE_TYPE_UNIFORM_BUFFER:
       case SPVC_RESOURCE_TYPE_STORAGE_BUFFER:
       case SPVC_RESOURCE_TYPE_STAGE_INPUT:
       case SPVC_RESOURCE_TYPE_SAMPLED_IMAGE:
           break;

       default:
          assert(0);
    }

    ptr = ctx->state.program;
    assert(ptr);

    return ptr->spirv_resources_list[stage][type].list[index].location;
}

- (id<MTLLibrary>) compileShader: (const char *) str
{
    id<MTLLibrary> library;
    __autoreleasing NSError *error = nil;

    library = [_device newLibraryWithSource: [NSString stringWithUTF8String: str] options: nil error: &error];
    assert(library);

    return library;
}

-(bool)bindMTLProgram:(Program *)ptr
{
    id<MTLLibrary> library;
    id<MTLFunction> function;
    Shader *shader;

    if (ptr->dirty_bits & DIRTY_PROGRAM)
    {
        char *src;
        size_t len;

        // build a single string from all shader source
        len = 0;
        for(int i=_VERTEX_SHADER; i<_MAX_SHADER_TYPES; i++)
        {
            if (ptr->spirv[i].msl_str)
            {
                len += strlen(ctx->state.program->spirv[i].msl_str) + 1024;
            }
        }

        src = (char *)malloc(len);
        *src = 0;

        for(int i=_VERTEX_SHADER; i<_MAX_SHADER_TYPES; i++)
        {
            if (ptr->spirv[i].msl_str)
            {
                strcat(src, ctx->state.program->spirv[i].msl_str);
            }
        }

        // release mtl shaders
        for(int i=_VERTEX_SHADER; i<_MAX_SHADER_TYPES; i++)
        {
            shader = ptr->shader_slots[i];

            if (shader)
            {
                if (shader->mtl_data)
                {
                    CFBridgingRelease(shader->mtl_data);
                    shader->mtl_data = NULL;
                }
            }
        }

        // release library
        if (ptr->mtl_data)
        {
            CFBridgingRelease(ptr->mtl_data);
            ptr->mtl_data = NULL;
        }

        // compile all shaders into library
        library = [self compileShader: src];
        assert(library);

        ptr->mtl_data = (void *)CFBridgingRetain(library);

        ptr->dirty_bits &= ~DIRTY_PROGRAM;
    }

    library = (__bridge id<MTLLibrary>)(ctx->state.program->mtl_data);
    assert(library);

    // bind mtl functions to shaders
    for(int i=_VERTEX_SHADER; i<_MAX_SHADER_TYPES; i++)
    {
        shader = ptr->shader_slots[i];

        if (shader)
        {
            if (shader->mtl_data == NULL)
            {
                function = [library newFunctionWithName:[NSString stringWithUTF8String: shader->entry_point]];
                assert(function);
                shader->mtl_data = (void *)CFBridgingRetain(function);

            }
        }
    }

    return true;
}

#pragma mark draw buffers
- (id)newDrawBuffer:(MTLPixelFormat)pixelFormat isDepthStencil:(bool)depthStencil
{
    id<MTLTexture> texture;
    MTLTextureDescriptor *tex_desc;
    NSRect frame;

    assert(_layer);
    frame = [_layer frame];

    tex_desc = [[MTLTextureDescriptor alloc] init];
    tex_desc.width = frame.size.width;
    tex_desc.height = frame.size.height;
    tex_desc.width = frame.size.width;
    tex_desc.pixelFormat = pixelFormat;
    tex_desc.usage = MTLTextureUsageRenderTarget;

    if (depthStencil)
    {
        tex_desc.storageMode = MTLStorageModePrivate;
    }

    texture = [_device newTextureWithDescriptor:tex_desc];
    assert(texture);

    return texture;
}

- (bool) checkDrawBufferSize:(GLuint) index;
{
    NSRect frame;
    NSSize size;

    frame = [_view frame];
    size = frame.size;

    if (size.width != _drawBuffers[index].width)
        return false;

    if (size.height != _drawBuffers[index].height)
        return false;

    return true;
}

#pragma mark render encoder and command buffer init code
- (MTLStencilOperation) mtlStencilOpForGLOp:(GLenum) op
{
    MTLStencilOperation stencil_op;

    switch(ctx->state.var.stencil_fail)
    {
        case GL_KEEP: stencil_op = MTLStencilOperationKeep; break;
        case GL_ZERO: stencil_op = MTLStencilOperationZero; break;
        case GL_REPLACE: stencil_op = MTLStencilOperationReplace; break;
        case GL_INCR: stencil_op = MTLStencilOperationIncrementClamp; break;
        case GL_INCR_WRAP: stencil_op = MTLStencilOperationDecrementClamp; break;
        case GL_DECR: stencil_op = MTLStencilOperationInvert; break;
        case GL_DECR_WRAP: stencil_op = MTLStencilOperationIncrementWrap; break;
        case GL_INVERT: stencil_op = MTLStencilOperationDecrementWrap; break;
        default:
            assert(0);
    }

    return stencil_op;
}

- (void) updateCurrentRenderEncoder
{
    if (ctx->state.caps.depth_test ||
        ctx->state.caps.stencil_test)
    {
        MTLDepthStencilDescriptor *dsDesc = [[MTLDepthStencilDescriptor alloc] init];

        // mtl maps directly to gl
        if (ctx->state.caps.depth_test)
        {
            dsDesc.depthCompareFunction = ctx->state.var.depth_func - GL_NEVER;

            dsDesc.depthWriteEnabled = ctx->state.var.depth_writemask;
        }

        if (ctx->state.caps.stencil_test)
        {
            // mtl maps directly to gl
            if (ctx->state.var.stencil_func != GL_NEVER)
            {
                MTLStencilDescriptor *frontSDesc = [[MTLStencilDescriptor alloc] init];

                frontSDesc.stencilCompareFunction = ctx->state.var.stencil_func - GL_NEVER;
                frontSDesc.stencilFailureOperation = [self mtlStencilOpForGLOp:ctx->state.var.stencil_fail ];
                frontSDesc.depthFailureOperation = [self mtlStencilOpForGLOp:ctx->state.var.stencil_pass_depth_fail];
                frontSDesc.depthStencilPassOperation = [self mtlStencilOpForGLOp:ctx->state.var.stencil_pass_depth_pass];
                frontSDesc.writeMask = ctx->state.var.stencil_writemask;
                frontSDesc.readMask = ctx->state.var.stencil_value_mask;    // ????

                dsDesc.frontFaceStencil = frontSDesc;
            }

            if (ctx->state.var.stencil_func != GL_NEVER)
            {
                MTLStencilDescriptor *backSDesc = [[MTLStencilDescriptor alloc] init];

                backSDesc.stencilCompareFunction = ctx->state.var.stencil_back_func - GL_NEVER;
                backSDesc.stencilFailureOperation = [self mtlStencilOpForGLOp:ctx->state.var.stencil_back_fail ];
                backSDesc.depthFailureOperation = [self mtlStencilOpForGLOp:ctx->state.var.stencil_back_pass_depth_fail];
                backSDesc.depthStencilPassOperation = [self mtlStencilOpForGLOp:ctx->state.var.stencil_back_pass_depth_pass];
                backSDesc.writeMask = ctx->state.var.stencil_back_writemask;
                backSDesc.readMask = ctx->state.var.stencil_back_value_mask;    // ????

                dsDesc.backFaceStencil = backSDesc;
            }
        }

        id <MTLDepthStencilState> dsState = [_device
                                  newDepthStencilStateWithDescriptor:dsDesc];

        [_currentRenderEncoder setDepthStencilState: dsState];
    }

    if (ctx->state.caps.scissor_test)
    {
        MTLScissorRect rect;

        rect.x = ctx->state.var.scissor_box[0];
        rect.y = ctx->state.var.scissor_box[1];
        rect.width = ctx->state.var.scissor_box[2];
        rect.height = ctx->state.var.scissor_box[3];

        [_currentRenderEncoder setScissorRect:rect];
    }

    [_currentRenderEncoder setViewport:(MTLViewport){ctx->state.viewport[0], ctx->state.viewport[1],
                                        ctx->state.viewport[2], ctx->state.viewport[3],
                                        ctx->state.var.depth_range[0], ctx->state.var.depth_range[1]}];

    if (ctx->state.caps.cull_face)
    {
        MTLCullMode cull_mode;

        switch(ctx->state.var.cull_face_mode)
        {
            case GL_BACK: cull_mode = MTLCullModeBack; break;
            case GL_FRONT: cull_mode = MTLCullModeFront; break;
            default:
                cull_mode = MTLCullModeNone;
        }

        [_currentRenderEncoder setCullMode:cull_mode];

        MTLWinding winding;

        winding = ctx->state.var.front_face - GL_CW;

        [_currentRenderEncoder setFrontFacingWinding:winding];
    }

    if (ctx->state.caps.depth_clamp)
    {
        [_currentRenderEncoder setDepthClipMode: MTLDepthClipModeClamp];
    }

    if (ctx->state.var.polygon_mode == GL_LINES)
    {
        [_currentRenderEncoder setTriangleFillMode: MTLTriangleFillModeLines];
    }
}

- (bool) newRenderEncoder
{
    // grab the next drawable from CAMetalLayer
    if (_drawable == NULL)
    {
        assert(_layer);
        
        _drawable = [_layer nextDrawable];

        // late init of gl scissor box on attachment to window system
        NSRect frame;
        frame = [_layer frame];

        ctx->state.var.scissor_box[2] = frame.size.width;
        ctx->state.var.scissor_box[3] = frame.size.height;
    }

    _renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    assert(_renderPassDescriptor);

    //printf("%s New render pass descriptor %p\n", __FUNCTION__, _renderPassDescriptor);

    if (ctx->state.framebuffer)
    {
        Framebuffer *fbo;
        GLuint drawbuffer;

        fbo = ctx->state.framebuffer;
        drawbuffer = ctx->state.draw_buffer - GL_COLOR_ATTACHMENT0;
        assert(drawbuffer >= 0);
        assert(drawbuffer <= STATE(max_color_attachments));

        for (int i=0; i<MAX_COLOR_ATTACHMENTS; i++)
        {
            if (fbo->color_attachments[i].texture)
            {
                Texture *tex;

                tex = [self framebufferAttachmentTexture: &fbo->color_attachments[i]];
                assert(tex);

                _renderPassDescriptor.colorAttachments[i].texture = (__bridge id<MTLTexture> _Nullable)(tex->mtl_data);

                if (i == drawbuffer)
                {
                    GLuint width, height;

                    width = tex->levels[0].width;
                    height = tex->levels[0].height;

                    _renderPassDescriptor.renderTargetWidth = width;
                    _renderPassDescriptor.renderTargetHeight = height;
                }
            }

            // early out
            if ((fbo->color_attachment_bitfield >> (i+1)) == 0)
                break;
        }

        // depth attachment
        if (fbo->depth.texture)
        {
            Texture *tex;

            tex = [self framebufferAttachmentTexture: &fbo->depth];
            assert(tex);

            _renderPassDescriptor.depthAttachment.texture = (__bridge id<MTLTexture> _Nullable)(tex->mtl_data);
        }

        // stencil attachment
        if (fbo->stencil.texture)
        {
            Texture *tex;

            tex = [self framebufferAttachmentTexture: &fbo->stencil];
            assert(tex);

            _renderPassDescriptor.stencilAttachment.texture = (__bridge id<MTLTexture> _Nullable)(tex->mtl_data);
        }
    }
    else
    {
        GLuint mgl_drawbuffer;
        id<MTLTexture> texture, depth_texture, stencil_texture;

        switch(ctx->state.draw_buffer)
        {
            case GL_FRONT: mgl_drawbuffer = _FRONT; break;
            case GL_BACK: mgl_drawbuffer = _BACK; break;
            case GL_FRONT_LEFT: mgl_drawbuffer = _FRONT_LEFT; break;
            case GL_FRONT_RIGHT: mgl_drawbuffer = _FRONT_RIGHT; break;
            case GL_BACK_LEFT: mgl_drawbuffer = _BACK_LEFT; break;
            case GL_BACK_RIGHT: mgl_drawbuffer = _BACK_RIGHT; break;
            default:
                assert(0);
        }

        if([self checkDrawBufferSize:mgl_drawbuffer])
        {
            _drawBuffers[mgl_drawbuffer].drawbuffer = NULL;
            _drawBuffers[mgl_drawbuffer].depthbuffer = NULL;
            _drawBuffers[mgl_drawbuffer].stencilbuffer = NULL;
        }

        // attach color buffer
        if (mgl_drawbuffer == _FRONT)
        {
            texture = _drawable.texture;
            assert(texture);
        }
        else if(_drawBuffers[mgl_drawbuffer].drawbuffer)
        {
            texture = _drawBuffers[mgl_drawbuffer].drawbuffer;
        }
        else
        {
            texture = [self newDrawBuffer: ctx->pixel_format.mtl_pixel_format isDepthStencil:false];
            _drawBuffers[mgl_drawbuffer].drawbuffer = texture;
        }

        // attach depth
        if (ctx->depth_format.format &&
            ctx->state.caps.depth_test)
        {
            if(_drawBuffers[mgl_drawbuffer].depthbuffer)
            {
                depth_texture = _drawBuffers[mgl_drawbuffer].depthbuffer;
            }
            else
            {
                depth_texture = [self newDrawBuffer: ctx->depth_format.mtl_pixel_format isDepthStencil:true];
                _drawBuffers[mgl_drawbuffer].depthbuffer = depth_texture;
            }

        }

        // attach stencil
        if (ctx->stencil_format.format &&
            ctx->state.caps.stencil_test)
        {
            if(_drawBuffers[mgl_drawbuffer].stencilbuffer)
            {
                stencil_texture = _drawBuffers[mgl_drawbuffer].stencilbuffer;
            }
            else
            {
                stencil_texture = [self newDrawBuffer: ctx->stencil_format.mtl_pixel_format isDepthStencil:true];
                _drawBuffers[mgl_drawbuffer].stencilbuffer = stencil_texture;
            }
        }

        _renderPassDescriptor.colorAttachments[0].texture = texture;
        _renderPassDescriptor.depthAttachment.texture = depth_texture;
        _renderPassDescriptor.stencilAttachment.texture = stencil_texture;

        _renderPassDescriptor.renderTargetWidth = texture.width;
        _renderPassDescriptor.renderTargetHeight = texture.height;
    }

    if (ctx->state.clear_bitmask)
    {
        if (ctx->state.clear_bitmask & GL_COLOR_BUFFER_BIT)
        {
            _renderPassDescriptor.colorAttachments[0].clearColor =
                MTLClearColorMake(STATE(color_clear_value[0]),
                                  STATE(color_clear_value[1]),
                                  STATE(color_clear_value[2]),
                                  STATE(color_clear_value[3]));

            _renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
        }
        else
        {
            _renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionLoad;
        }

        if (ctx->state.clear_bitmask & GL_DEPTH_BUFFER_BIT)
        {
            _renderPassDescriptor.depthAttachment.clearDepth = STATE_VAR(depth_clear_value);

            _renderPassDescriptor.depthAttachment.loadAction = MTLLoadActionClear;
        }
        else
        {
            _renderPassDescriptor.depthAttachment.loadAction = MTLLoadActionLoad;
        }

        if (ctx->state.clear_bitmask & GL_STENCIL_BUFFER_BIT)
        {
            _renderPassDescriptor.stencilAttachment.clearStencil = STATE_VAR(stencil_clear_value);

            _renderPassDescriptor.stencilAttachment.loadAction = MTLLoadActionClear;
        }
        else
        {
            _renderPassDescriptor.stencilAttachment.loadAction = MTLLoadActionLoad;
        }

        ctx->state.clear_bitmask = 0;
    }
    else
    {
        _renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionLoad;
        _renderPassDescriptor.depthAttachment.loadAction = MTLLoadActionLoad;
        _renderPassDescriptor.stencilAttachment.loadAction = MTLLoadActionLoad;
    }

    _renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;

    // create a render encoder from the renderpass descriptor
    _currentRenderEncoder = [_currentCommandBuffer renderCommandEncoderWithDescriptor: _renderPassDescriptor];
    assert(_currentRenderEncoder);
    _currentRenderEncoder.label = @"GL Render Encoder";

    [self updateCurrentRenderEncoder];

    if (VAO() == NULL)
        return false;

    if ([self bindBuffersToCurrentRenderEncoder] == false)
        return false;

    if ([self bindTexturesToCurrentRenderEncoder] == false)
        return false;

    return true;
}

- (bool) newCommandBufferAndRenderEncoder
{
    if (_currentEvent)
    {
        assert(_currentSyncName);

        [_currentCommandBuffer encodeWaitForEvent: _currentEvent value: _currentSyncName];

        _currentEvent = NULL;
        _currentSyncName = 0;
    }

    // remove any events waiting on current command buffer
    if (_currentCommandBufferSyncList)
    {
        GLuint count;

        count = _currentCommandBufferSyncList->count;

        for(GLuint i=0; i<count; i++)
        {
            Sync *sync;

            sync = _currentCommandBufferSyncList->list[i];

            CFBridgingRelease(sync->mtl_event);
        }

        _currentCommandBufferSyncList->count = 0;
    }

    _currentCommandBuffer = [_commandQueue commandBuffer];
    assert(_currentCommandBuffer);

    //printf("%s New command buffer %p\n", __FUNCTION__, _currentCommandBuffer);

    if ([self newRenderEncoder] == false)
        return false;

    return true;
}

- (bool)bindMTLTexture:(Texture *)tex
{
    if (tex->mtl_data == NULL)
    {
        tex->mtl_data = (void *)CFBridgingRetain([self createMTLTextureFromGLTexture: tex]);

        tex->params.mtl_data = (void *)CFBridgingRetain([self createMTLSamplerForTexture:tex]);
    }

    return true;
}

- (bool)bindFramebufferTextureAsDrawBuffer:(FBOAttachment *)fbo_attachment
{
    Texture *tex;

    tex = [self framebufferAttachmentTexture: fbo_attachment];
    assert(tex);

    tex->is_render_target = true;

    [self bindMTLTexture: tex];

    return true;
}

- (bool)bindFramebufferTexture:(FBOAttachment *)fbo_attachment
{
    Texture *tex;

    tex = [self framebufferAttachmentTexture: fbo_attachment];
    assert(tex);

    tex->is_render_target = false;

    [self bindMTLTexture: tex];

    return true;
}

#pragma mark utility funcs for processGLState
- (MTLBlendFactor) blendFactorFromGL:(GLenum)gl_blend
{
    MTLBlendFactor factor;

    switch(gl_blend)
    {
        case GL_ZERO: factor = MTLBlendFactorZero; break;
        case GL_ONE: factor = MTLBlendFactorOne; break;
        case GL_SRC_COLOR: factor = MTLBlendFactorSourceColor; break;
        case GL_ONE_MINUS_SRC_COLOR: factor = MTLBlendFactorOneMinusSourceColor; break;
        case GL_DST_COLOR: factor = MTLBlendFactorDestinationColor; break;
        case GL_ONE_MINUS_DST_COLOR: factor = MTLBlendFactorOneMinusDestinationColor; break;
        case GL_SRC_ALPHA: factor = MTLBlendFactorSourceAlpha; break;
        case GL_ONE_MINUS_SRC_ALPHA: factor = MTLBlendFactorOneMinusSourceAlpha; break;
        case GL_DST_ALPHA: factor = MTLBlendFactorDestinationAlpha; break;
        case GL_ONE_MINUS_DST_ALPHA: factor = MTLBlendFactorOneMinusDestinationAlpha; break;
        case GL_CONSTANT_COLOR: factor = MTLBlendFactorSource1Color; break;
        case GL_ONE_MINUS_CONSTANT_COLOR: factor = MTLBlendFactorOneMinusSource1Color; break;
        case GL_CONSTANT_ALPHA: factor = MTLBlendFactorSource1Alpha; break;
        case GL_ONE_MINUS_CONSTANT_ALPHA: factor = MTLBlendFactorOneMinusSource1Alpha; break;

        default:
            assert(0);
    }

    return factor;
}

- (MTLBlendOperation) blendOperationFromGL:(GLenum)gl_blend_op
{
    MTLBlendOperation op;

    switch(gl_blend_op)
    {
        case GL_FUNC_ADD: op = MTLBlendOperationAdd; break;
        case GL_FUNC_SUBTRACT: op = MTLBlendOperationSubtract; break;
        case GL_FUNC_REVERSE_SUBTRACT: op = MTLBlendOperationReverseSubtract; break;
        case GL_MIN: op = MTLBlendOperationMin; break;
        case GL_MAX: op = MTLBlendOperationMax; break;
            break;

        default:
            assert(0);
    }

    return op;
}

#pragma mark main state resolving function processGLState

- (bool) processGLState: (bool) draw_command
{
    assert(_device);
    assert(_commandQueue);

    if (VAO() == NULL)
    {
        if (draw_command)
        {
            NSLog(@"Error: No VAO defined for ctx\n");

            // quietly return if we are not in a draw command with no vao defined
            // like a clear or init call
            return false;
        }

        // for a clear flush sequence...
        if (ctx->state.dirty_bits & DIRTY_STATE)
        {
            if (_currentRenderEncoder)
            {
                [_currentRenderEncoder endEncoding];
            }
            
            if ([self newRenderEncoder] == false)
                return false;
        }

        return true;
    }

    if (_currentRenderEncoder == NULL)
    {
        if ([self newRenderEncoder] == false)
            return false;
    }

    if (ctx->state.dirty_bits)
    {
        NSError *error = NULL;

        if (ctx->state.dirty_bits & DIRTY_STATE)
        {
            if (ctx->state.dirty_bits & DIRTY_FBO)
            {
                if (ctx->state.framebuffer)
                {
                    if (ctx->state.framebuffer->dirty_bits & DIRTY_FBO_BINDING)
                    {
                        Framebuffer *fbo;
                        GLuint drawbuffer;

                        fbo = ctx->state.framebuffer;
                        drawbuffer = ctx->state.draw_buffer - GL_COLOR_ATTACHMENT0;
                        assert(drawbuffer >= 0);
                        assert(drawbuffer <= STATE(max_color_attachments));

                        for (int i=0; i<MAX_COLOR_ATTACHMENTS; i++)
                        {
                            if (fbo->color_attachments[i].texture)
                            {
                                if (i == drawbuffer)
                                {
                                    if ([self bindFramebufferTextureAsDrawBuffer: &fbo->color_attachments[i]] == false)
                                    {
                                        printf("Failed Framebuffer Attachment\n");
                                        return false;
                                    }
                                }
                                else
                                {
                                    if ([self bindFramebufferTexture: &fbo->color_attachments[i]] == false)
                                    {
                                        printf("Failed Framebuffer Attachment\n");
                                        return false;
                                    }
                                }
                            }

                            // early out
                            if ((fbo->color_attachment_bitfield >> (i+1)) == 0)
                                break;
                        }

                        // depth attachment
                        if (fbo->depth.texture)
                        {
                            if ([self bindFramebufferTexture: &fbo->depth])
                            {
                                printf("Failed Framebuffer Attachment\n");
                                return false;
                            }
                        }

                        // stencil attachment
                        if (fbo->stencil.texture)
                        {
                            if ([self bindFramebufferTexture: &fbo->stencil])
                            {
                                printf("Failed Framebuffer Attachment\n");
                                return false;
                            }
                        }

                        ctx->state.framebuffer->dirty_bits &= ~DIRTY_FBO_BINDING;
                    }
                }
            }
        }
        
        if (ctx->state.dirty_bits & (DIRTY_PROGRAM | DIRTY_VAO))
        {
            assert(ctx->state.program->spirv[_VERTEX_SHADER].msl_str);

            // figure out vertex shader uniforms / buffer mappings
            if ([self mapBuffersToMTL] == false)
            {
                return false;
            }
        }

        if (ctx->state.dirty_bits & DIRTY_TEX)
        {
            // search through active_texture_mask for enabled bits
            // 128 bits long.. do it on 4 parts
            for(int i=0; i<4; i++)
            {
                unsigned mask = STATE(active_texture_mask[i]);

                if (mask)
                {
                    for(int bitpos=0; bitpos<32; bitpos++)
                    {
                        if (mask & (0x1 << bitpos))
                        {
                            Texture *tex;

                            tex = STATE(active_textures[i*32+bitpos]);
                            assert(tex);

                            [self bindMTLTexture: tex];
                        }

                        // early out
                        if ((mask >> (bitpos + 1)) == 0)
                            break;
                    }
                }
            }

            ctx->state.dirty_bits &= ~DIRTY_TEX;
        }

        if (ctx->state.dirty_bits & DIRTY_BUFFER)
        {
            [self updateDirtyBaseBufferList: &ctx->state.vertex_buffer_map_list];
            [self updateDirtyBaseBufferList: &ctx->state.fragment_buffer_map_list];
        }

        if (ctx->state.dirty_bits & DIRTY_VAO)
        {
            // we have a dirty VAO, all the renderbuffer bindings are invalid so we need a new renderbuffer
            // with new renderbuffer bindings

            // always end encoding and start a new encoder
            assert(_currentRenderEncoder);
            [_currentRenderEncoder endEncoding];

            [self updateDirtyBaseBufferList: &ctx->state.vertex_buffer_map_list];
            [self updateDirtyBaseBufferList: &ctx->state.fragment_buffer_map_list];

            // get a new renderer encoder
            if ([self newRenderEncoder] == false)
                return false;
        }
        else if (ctx->state.dirty_bits & DIRTY_RENDER_STATE)
        {
            // call this since newRenderEncoder will update the renderstate
            [self updateCurrentRenderEncoder];

            ctx->state.dirty_bits &= ~DIRTY_RENDER_STATE;
        }

        // new pipeline / vertex / renderbuffer descriptor, should probably make this a single dirty bit
        if (ctx->state.dirty_bits & (DIRTY_PROGRAM | DIRTY_VAO | DIRTY_FBO))
        {
            Program *program;
            Shader *vertex_shader, *fragment_shader;
            id<MTLFunction> vertexFunction;
            id<MTLFunction> fragmentFunction;

            if (ctx->state.dirty_bits & DIRTY_PROGRAM)
            {
                program = ctx->state.program;

                if (program)
                {
                    if ([self bindMTLProgram:program] == false)
                        return false;
                }
                else
                {
                    return false;
                }
            }

            program = ctx->state.program;
            vertex_shader = program->shader_slots[_VERTEX_SHADER];
            fragment_shader = program->shader_slots[_FRAGMENT_SHADER];
            assert(vertex_shader);
            assert(fragment_shader);

            vertexFunction = (__bridge id<MTLFunction>)(vertex_shader->mtl_data);
            fragmentFunction = (__bridge id<MTLFunction>)(fragment_shader->mtl_data);
            assert(vertexFunction);
            assert(fragmentFunction);

            // Configure a pipeline descriptor that is used to create a pipeline state.
            MTLRenderPipelineDescriptor *pipelineStateDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
            assert(pipelineStateDescriptor);
            pipelineStateDescriptor.label = @"GLSL Pipeline";
            pipelineStateDescriptor.vertexFunction = vertexFunction;
            pipelineStateDescriptor.fragmentFunction = fragmentFunction;

            if (ctx->state.framebuffer)
            {
                Framebuffer *fbo;
                GLuint drawbuffer;

                fbo = ctx->state.framebuffer;
                drawbuffer = ctx->state.draw_buffer - GL_COLOR_ATTACHMENT0;
                assert(drawbuffer >= 0);
                assert(drawbuffer <= STATE(max_color_attachments));

                for (int i=0; i<STATE(max_color_attachments); i++)
                {
                    if (fbo->color_attachments[i].texture)
                    {
                        Texture *tex;

                        tex = [self framebufferAttachmentTexture: &fbo->color_attachments[i]];
                        assert(tex);

                        [self bindMTLTexture: tex];

                        pipelineStateDescriptor.colorAttachments[i].pixelFormat = mtlPixelFormatForGLTex(tex);
                    }

                    // early out
                    if ((fbo->color_attachment_bitfield >> (i+1)) == 0)
                        break;
                }

                // depth attachment
                if (fbo->depth.texture &&
                    ctx->state.caps.depth_test)
                {
                    Texture *tex;

                    tex = [self framebufferAttachmentTexture: &fbo->depth];
                    assert(tex);

                    [self bindMTLTexture: tex];

                    pipelineStateDescriptor.depthAttachmentPixelFormat = mtlPixelFormatForGLTex(tex);
                }

                // stencil attachment
                if (fbo->stencil.texture &&
                    ctx->state.caps.stencil_test)
                {
                    Texture *tex;

                    tex = [self framebufferAttachmentTexture: &fbo->stencil];
                    assert(tex);

                    [self bindMTLTexture: tex];

                    pipelineStateDescriptor.depthAttachmentPixelFormat = mtlPixelFormatForGLTex(tex);
                }
            }
            else
            {
                pipelineStateDescriptor.colorAttachments[0].pixelFormat = ctx->pixel_format.mtl_pixel_format;

                if (ctx->depth_format.format &&
                    ctx->state.caps.depth_test)
                    pipelineStateDescriptor.depthAttachmentPixelFormat = ctx->depth_format.mtl_pixel_format;

                if (ctx->stencil_format.format &&
                    ctx->state.caps.stencil_test)
                    pipelineStateDescriptor.stencilAttachmentPixelFormat = ctx->stencil_format.mtl_pixel_format;
            }

            // create vertex descriptor
            MTLVertexDescriptor *vertexDescriptor = [[MTLVertexDescriptor alloc] init];
            assert(vertexDescriptor);

            [vertexDescriptor reset]; // ??? debug

            // we can bind a new vertex descriptor without creating a new renderbuffer
            for(int i=0;i<ctx->state.max_vertex_attribs; i++)
            {
                if (VAO_STATE(enabled_attribs) & (0x1 << i))
                {
                    MTLVertexFormat format;

                    if (VAO_ATTRIB_STATE(i).buffer == NULL)
                    {
                        NSLog(@"Error: Invalid VAO defined enabled but no buffer bound\n");
                        return false;
                    }

                    format = glTypeSizeToMtlType(VAO_ATTRIB_STATE(i).type,
                                                 VAO_ATTRIB_STATE(i).size,
                                                 VAO_ATTRIB_STATE(i).normalized);

                    if (format == MTLVertexFormatInvalid)
                    {
                        NSLog(@"Error: unable to map gl type / size / normalize to format\n");
                        return false;
                    }

                    int mapped_buffer_index;

                    mapped_buffer_index = [self getVertexBufferIndexWithAttributeSet: i];

                    vertexDescriptor.attributes[i].bufferIndex = mapped_buffer_index;
                    vertexDescriptor.attributes[i].offset = 0;
                    vertexDescriptor.attributes[i].format = format;

                    assert(VAO_ATTRIB_STATE(i).stride); // find these issues
                    vertexDescriptor.layouts[mapped_buffer_index].stride = VAO_ATTRIB_STATE(i).stride;
                    vertexDescriptor.layouts[mapped_buffer_index].stepRate = 1;
                    vertexDescriptor.layouts[mapped_buffer_index].stepFunction = MTLVertexStepFunctionPerVertex;
                }

                // early out
                if ((VAO_STATE(enabled_attribs) >> (i+1)) == 0)
                    break;
            }

            if (ctx->state.caps.blend)
            {
                // cache these rather than recalculating them each time
                if (ctx->state.dirty_bits & DIRTY_ALPHA_STATE)
                {
                    for(int i=0; i<MAX_COLOR_ATTACHMENTS; i++)
                    {
                        _src_blend_rgb_factor[i] = [self blendFactorFromGL:ctx->state.var.blend_src_rgb[i]];
                        _src_blend_alpha_factor[i] = [self blendFactorFromGL:ctx->state.var.blend_src_alpha[i]];

                        _dst_blend_rgb_factor[i] = [self blendFactorFromGL:ctx->state.var.blend_dst_rgb[i]];
                        _dst_blend_alpha_factor[i] = [self blendFactorFromGL:ctx->state.var.blend_dst_alpha[i]];

                        _rgb_blend_operation[i] = [self blendOperationFromGL: ctx->state.var.blend_equation_rgb[i]];
                        _alpha_blend_operation[i] = [self blendOperationFromGL: ctx->state.var.blend_equation_alpha[i]];

                        if (ctx->state.caps.use_color_mask[i])
                        {
                            _color_mask[i] = MTLColorWriteMaskNone;

                            if (ctx->state.var.color_writemask[i][0])
                                _color_mask[i] |= MTLColorWriteMaskRed;

                            if (ctx->state.var.color_writemask[i][1])
                                _color_mask[i] |= MTLColorWriteMaskGreen;

                            if (ctx->state.var.color_writemask[i][2])
                                _color_mask[i] |= MTLColorWriteMaskBlue;

                            if (ctx->state.var.color_writemask[i][3])
                                _color_mask[i] |= MTLColorWriteMaskAlpha;
                        }
                        else
                        {
                            _color_mask[i] = MTLColorWriteMaskNone;
                        }
                    }

                    ctx->state.dirty_bits &= ~DIRTY_ALPHA_STATE;
                }

                for(int i=0; i<MAX_COLOR_ATTACHMENTS; i++)
                {
                    if (pipelineStateDescriptor.colorAttachments[i].pixelFormat != MTLPixelFormatInvalid)
                    {
                        pipelineStateDescriptor.colorAttachments[i].blendingEnabled = true;

                        pipelineStateDescriptor.colorAttachments[i].sourceRGBBlendFactor = _src_blend_rgb_factor[i];
                        pipelineStateDescriptor.colorAttachments[i].destinationRGBBlendFactor = _dst_blend_rgb_factor[i];
                        pipelineStateDescriptor.colorAttachments[i].sourceAlphaBlendFactor = _src_blend_alpha_factor[i];
                        pipelineStateDescriptor.colorAttachments[i].destinationAlphaBlendFactor = _dst_blend_alpha_factor[i];

                        pipelineStateDescriptor.colorAttachments[i].rgbBlendOperation = _rgb_blend_operation[i];
                        pipelineStateDescriptor.colorAttachments[i].alphaBlendOperation = _alpha_blend_operation[i];

                        pipelineStateDescriptor.colorAttachments[i].writeMask = _color_mask[i];
                    }
                }
            }

            pipelineStateDescriptor.vertexDescriptor = vertexDescriptor;

            _pipelineState = [_device newRenderPipelineStateWithDescriptor: pipelineStateDescriptor
                                                                     error:&error];

            // Pipeline State creation could fail if the pipeline descriptor isn't set up properly.
            //  If the Metal API validation is enabled, you can find out more information about what
            //  went wrong.  (Metal API validation is enabled by default when a debug build is run
            //  from Xcode.)
            NSAssert(_pipelineState, @"Failed to created pipeline state: %@", error);

            ctx->state.dirty_bits &= ~(DIRTY_PROGRAM | DIRTY_VAO | DIRTY_FBO);
        }

        ctx->state.dirty_bits = 0;
    }


    // fix this
    // Create a render command encoder.

    [_currentRenderEncoder setRenderPipelineState: _pipelineState];

    return true;
}

-(bool) processElementBuffer
{
    // check all the buffers for metal objects
    Buffer *gl_buffer = VAO_STATE(element_array.buffer);

    if (gl_buffer == NULL)
    {
        NSLog(@"Error: processElementBuffer failed\n");

        return false;
    }

    if (gl_buffer->data.dirty_bits)
    {
        if (gl_buffer->data.dirty_bits & DIRTY_BUFFER_ADDR)
        {
            if (gl_buffer->data.mtl_data == NULL)
            {
                id <MTLBuffer> buffer = [self createMTLBufferFromGLMBuffer: gl_buffer];

                [buffer didModifyRange: NSMakeRange(0, gl_buffer->data.buffer_size)];

                gl_buffer->data.mtl_data = (void *)CFBridgingRetain(buffer);

                assert(gl_buffer->data.mtl_data);

                // clear dirty bits
                gl_buffer->data.dirty_bits = 0;
            }
        }
        else if (gl_buffer->data.dirty_bits & DIRTY_BUFFER_DATA)
        {
            id<MTLBuffer> buffer = (__bridge id<MTLBuffer>)(gl_buffer->data.mtl_data);

            assert(buffer);

            [buffer didModifyRange: NSMakeRange(0, gl_buffer->data.buffer_size)];

            // clear dirty bits if not mapped as coherent
            // this will cause us to keep loading the buffer and keep the GPU
            // contents in check for EVERY drawing operation
            if (gl_buffer->access & GL_MAP_COHERENT_BIT)
            {
                [buffer didModifyRange: NSMakeRange(gl_buffer->mapped_offset, gl_buffer->mapped_length)];

                gl_buffer->data.dirty_bits = DIRTY_BUFFER_DATA;
            }
            else
            {
                [buffer didModifyRange: NSMakeRange(gl_buffer->mapped_offset, gl_buffer->mapped_length)];

                gl_buffer->data.dirty_bits = 0;
            }
        }
        else
        {
            NSLog(@"Error: processElementBuffer failed\n");

            return false;

            assert(0);
        }
    }

    return true;
}

-(void) flushCommandBuffer: (bool) finish
{
    if ([self processGLState: false] == false)
    {
        return;
    }

    // always these three in order
    // end encoding
    assert(_currentRenderEncoder);
    [_currentRenderEncoder endEncoding];

    // Finalize rendering here & push the command buffer to the GPU.
    assert(_currentCommandBuffer);
    [_currentCommandBuffer commit];

    if (finish)
    {
        [_currentCommandBuffer waitUntilCompleted];
    }

    // get a new command buffer renderer encoder
    [self newCommandBufferAndRenderEncoder];
}

#pragma mark C interface to mtlDeleteMTLBuffer
-(void) mtlDeleteMTLBuffer:(GLMContext) glm_ctx buffer: (void *)buffer
{
    if ([self processGLState: false] == false)
    {
        return;
    }

    [self flushCommandBuffer: false];

    // this should release it to the GC
    CFBridgingRelease(buffer);
}

void mtlDeleteMTLBuffer (GLMContext glm_ctx, void *buf)
{
    // Call the Objective-C method using Objective-C syntax
    [(__bridge id) glm_ctx->mtl_funcs.mtlObj mtlDeleteMTLBuffer: glm_ctx buffer: buf];
}

#pragma mark C interface to mtlDeleteMTLTexture
-(void) mtlDeleteMTLTexture:(GLMContext) glm_ctx tex: (void *)tex
{
    if ([self processGLState: false] == false)
    {
        return;
    }

    [self flushCommandBuffer: false];

    // this should release it to the GC
    CFBridgingRelease(tex);
}

void mtlDeleteMTLTexture (GLMContext glm_ctx, void *tex)
{
    // Call the Objective-C method using Objective-C syntax
    [(__bridge id) glm_ctx->mtl_funcs.mtlObj mtlDeleteMTLTexture: glm_ctx tex: tex];
}


#pragma mark C interface to mtlGetSync
-(void) mtlGetSync:(GLMContext) glm_ctx sync: (Sync *)sync
{
    if ([self processGLState: false] == false)
    {
        return;
    }

    if (_currentEvent == NULL)
    {
        _currentEvent = [_device newEvent];
        assert(_currentEvent);
    }

    _currentSyncName = sync->name;

    sync->mtl_event = (void *)CFBridgingRetain(_currentEvent);

    if (_currentCommandBufferSyncList == NULL)
    {
        _currentCommandBufferSyncList = (SyncList *)malloc(sizeof(SyncList));
        assert(_currentCommandBufferSyncList);

        _currentCommandBufferSyncList->size = 8;
        _currentCommandBufferSyncList->list = (Sync **)malloc(sizeof(Sync *) * 8);
        assert(_currentCommandBufferSyncList->list);

        _currentCommandBufferSyncList->count = 0;
    }

    _currentCommandBufferSyncList->list[_currentCommandBufferSyncList->count] = sync;
    _currentCommandBufferSyncList->count++;

    if (_currentCommandBufferSyncList->count >= _currentCommandBufferSyncList->size)
    {
        _currentCommandBufferSyncList->size *= 2;
        _currentCommandBufferSyncList->list = (Sync **)realloc(_currentCommandBufferSyncList->list,
                                                                sizeof(Sync *) * _currentCommandBufferSyncList->size);
        assert(_currentCommandBufferSyncList->list);
    }
}

void mtlGetSync (GLMContext glm_ctx, Sync *sync)
{
    // Call the Objective-C method using Objective-C syntax
    [(__bridge id) glm_ctx->mtl_funcs.mtlObj mtlGetSync: glm_ctx sync: sync];
}

#pragma mark C interface to mtlWaitForSync
-(void) mtlWaitForSync:(GLMContext) glm_ctx sync: (Sync *)sync
{
    if ([self processGLState: false] == false)
    {
        return;
    }

    assert(sync->mtl_event);

    CFBridgingRelease(sync->mtl_event);

    sync->mtl_event = NULL;
}

void mtlWaitForSync (GLMContext glm_ctx, Sync *sync)
{
    // Call the Objective-C method using Objective-C syntax
    [(__bridge id) glm_ctx->mtl_funcs.mtlObj mtlWaitForSync: glm_ctx sync: sync];
}

#pragma mark C interface to mtlFlush
-(void) mtlFlush:(GLMContext) glm_ctx finish:(bool)finish
{
    [self flushCommandBuffer: finish];
}

void mtlFlush (GLMContext glm_ctx, bool finish)
{
    // Call the Objective-C method using Objective-C syntax
    [(__bridge id) glm_ctx->mtl_funcs.mtlObj mtlFlush:glm_ctx finish:finish];
}

#pragma mark C interface to mtlSwapBuffers
-(void) mtlSwapBuffers:(GLMContext) glm_ctx
{
    if ([self processGLState: false] == false)
    {
        return;
    }

    assert(_currentRenderEncoder);
    assert(_currentCommandBuffer);

    //printf("%s\n", __FUNCTION__);

    if (ctx->state.draw_buffer == GL_FRONT)
    {
        [_currentCommandBuffer presentDrawable: _drawable];

        _drawable = [_layer nextDrawable];
    }

    [self flushCommandBuffer: false];
}

void mtlSwapBuffers (GLMContext glm_ctx)
{
    // Call the Objective-C method using Objective-C syntax
    [(__bridge id) glm_ctx->mtl_funcs.mtlObj mtlSwapBuffers: glm_ctx];
}

#pragma mark C interface to mtlClearBuffer
-(void) mtlClearBuffer:(GLMContext) glm_ctx type:(GLuint) type mask:(GLbitfield) mask
{
    if ([self processGLState: false] == false)
    {
        return;
    }
}

void mtlClearBuffer (GLMContext glm_ctx, GLuint type, GLbitfield mask)
{
    // Call the Objective-C method using Objective-C syntax
    [(__bridge id) glm_ctx->mtl_funcs.mtlObj mtlClearBuffer: glm_ctx type: type mask: mask];
}

#pragma mark C interface to mtlBufferSubData

-(void) mtlBufferSubData:(GLMContext) glm_ctx buf:(Buffer *)buf offset:(size_t)offset size:(size_t)size ptr:(const void *)ptr
{
    id<MTLBuffer> mtl_buffer;
    void *data;

    // simple hack to save another function def, use buffer sub to create a buffer
    if (ptr == NULL)
    {
        [self createMTLBufferFromGLMBuffer: buf];

        return;
    }

    mtl_buffer = (__bridge id<MTLBuffer>)(buf->data.mtl_data);

    data = mtl_buffer.contents;
    memcpy(data+offset, ptr, size);

    [mtl_buffer didModifyRange:NSMakeRange(offset, size)];
}

void mtlBufferSubData(GLMContext glm_ctx, Buffer *buf, size_t offset, size_t size, const void *ptr)
{
    // Call the Objective-C method using Objective-C syntax
    [(__bridge id) glm_ctx->mtl_funcs.mtlObj mtlBufferSubData: glm_ctx buf: buf offset:offset size:size ptr:ptr];
}

#pragma mark C interface to mtlMapUnmapBuffer
-(void *) mtlMapUnmapBuffer:(GLMContext) glm_ctx buf:(Buffer *)buf offset:(size_t) offset size:(size_t) size access:(GLenum) access map:(bool)map
{
    id<MTLBuffer> mtl_buffer;

    mtl_buffer = (__bridge id<MTLBuffer>)(buf->data.mtl_data);

    if (map)
    {
        return mtl_buffer.contents + offset;
    }

    [mtl_buffer didModifyRange:NSMakeRange(offset, size)];

    return NULL;
}

void *mtlMapUnmapBuffer(GLMContext glm_ctx, Buffer *buf, size_t offset, size_t size, GLenum access, bool map)
{
    // Call the Objective-C method using Objective-C syntax
    return [(__bridge id) glm_ctx->mtl_funcs.mtlObj mtlMapUnmapBuffer: glm_ctx buf: buf offset: offset size: size access: access map: map];
}

#pragma mark C interface to mtlFlushMappedBufferRange
-(void) mtlFlushMappedBufferRange:(GLMContext) glm_ctx buf:(Buffer *)buf offset:(size_t) offset length:(size_t) length
{
    id<MTLBuffer> mtl_buffer;

    mtl_buffer = (__bridge id<MTLBuffer>)(buf->data.mtl_data);

    [mtl_buffer didModifyRange:NSMakeRange(offset, length)];
}

void mtlFlushBufferRange(GLMContext glm_ctx, Buffer *buf, GLintptr offset, GLsizeiptr length)
{
    // Call the Objective-C method using Objective-C syntax
    [(__bridge id) glm_ctx->mtl_funcs.mtlObj mtlFlushMappedBufferRange: glm_ctx buf: buf offset: offset length: length];
}


#pragma mark C interface to mtlGetTexImage
-(void) mtlGetTexImage:(GLMContext) glm_ctx tex: (Texture *)tex pixelBytes:(void *)pixelBytes bytesPerRow:(NSUInteger)bytesPerRow bytesPerImage:(NSUInteger)bytesPerImage fromRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice
{
    id<MTLTexture> texture;

    //[self processGLState: false];

    // flush finish
    [self mtlFlush:glm_ctx finish:true];

    if (tex)
    {
        texture = (__bridge id<MTLTexture>)(tex->mtl_data);
        assert(texture);
    }
    else
    {
        if (glm_ctx->state.readbuffer)
        {
            Framebuffer *fbo;
            GLuint drawbuffer;

            fbo = ctx->state.readbuffer;
            drawbuffer = ctx->state.read_buffer - GL_COLOR_ATTACHMENT0;
            assert(drawbuffer >= 0);
            assert(drawbuffer <= STATE(max_color_attachments));

            tex = [self framebufferAttachmentTexture: &fbo->color_attachments[drawbuffer]];
            assert(tex);

            texture = (__bridge id<MTLTexture>)(tex->mtl_data);
            assert(texture);
        }
        else
        {
            GLuint mgl_drawbuffer;
            id<MTLTexture> texture;

            switch(ctx->state.read_buffer)
            {
                case GL_FRONT: mgl_drawbuffer = _FRONT; break;
                case GL_BACK: mgl_drawbuffer = _BACK; break;
                case GL_FRONT_LEFT: mgl_drawbuffer = _FRONT_LEFT; break;
                case GL_FRONT_RIGHT: mgl_drawbuffer = _FRONT_RIGHT; break;
                case GL_BACK_LEFT: mgl_drawbuffer = _BACK_LEFT; break;
                case GL_BACK_RIGHT: mgl_drawbuffer = _BACK_RIGHT; break;
                default:
                    assert(0);
            }

            if (mgl_drawbuffer == _FRONT)
            {
                texture = _drawable.texture;
                assert(texture);
            }
            else if(_drawBuffers[mgl_drawbuffer].drawbuffer)
            {
                texture = _drawBuffers[mgl_drawbuffer].drawbuffer;
            }
            else
            {
                assert(0);
            }
        }
    }

    if ([texture isFramebufferOnly] == NO)
    {
        [texture getBytes:pixelBytes bytesPerRow:bytesPerRow bytesPerImage:bytesPerImage fromRegion:region mipmapLevel:level slice:slice];
    }
    else
    {
        // issue a gl error as we can't read a framebuffer only texture
        NSLog(@"Cannot read from framebuffer only texture\n");
        ctx->error_func(ctx, __FUNCTION__, GL_INVALID_OPERATION);
    }
}

void mtlGetTexImage(GLMContext glm_ctx, Texture *tex, void *pixelBytes, GLuint bytesPerRow, GLuint bytesPerImage, GLint x, GLint y, GLsizei width, GLsizei height, GLuint level, GLuint slice)
{
    [(__bridge id) glm_ctx->mtl_funcs.mtlObj mtlGetTexImage:glm_ctx tex:tex pixelBytes:pixelBytes bytesPerRow:bytesPerRow bytesPerImage:bytesPerImage fromRegion:MTLRegionMake2D(x,y,width,height) mipmapLevel:level slice:slice];
}


#pragma mark utility functions for draw commands
MTLPrimitiveType getMTLPrimitiveType(GLenum mode)
{
    const GLuint err = 0xFFFFFFFF;

    switch(mode)
    {
        case GL_POINTS:
            return MTLPrimitiveTypePoint;

        case GL_LINES:
            return MTLPrimitiveTypeLine;

        case GL_LINE_STRIP:
            return MTLPrimitiveTypeLineStrip;

        case GL_TRIANGLES:
            return MTLPrimitiveTypeTriangle;

        case GL_TRIANGLE_STRIP:
            return MTLPrimitiveTypeTriangleStrip;

        case GL_LINE_LOOP:
        case GL_LINE_STRIP_ADJACENCY:
        case GL_LINES_ADJACENCY:
        case GL_TRIANGLE_FAN:
        case GL_TRIANGLE_STRIP_ADJACENCY:
        case GL_PATCHES:
            assert(0);
            break;
    }

    return err;
}

MTLIndexType getMTLIndexType(GLenum type)
{
    const GLuint err = 0xFFFFFFFF;

    switch(type)
    {
        case GL_UNSIGNED_SHORT:
            return MTLIndexTypeUInt16;

        case GL_UNSIGNED_INT:
            return MTLIndexTypeUInt32;
    }

    return err;

}

Buffer *getElementBuffer(GLMContext ctx)
{
    Buffer *gl_element_buffer = VAO_STATE(element_array.buffer);

    return gl_element_buffer;
}

#pragma mark C interface to mtlDrawArrays
-(void) mtlDrawArrays: (GLMContext) ctx mode:(GLenum) mode first: (GLint) first count: (GLsizei) count
{
    MTLPrimitiveType primitiveType;

    if ([self processGLState: true] == false)
    {
        return;
    }

    primitiveType = getMTLPrimitiveType(mode);
    assert(primitiveType != 0xFFFFFFFF);

     [_currentRenderEncoder drawPrimitives: primitiveType
                              vertexStart: first
                              vertexCount: count];
}

void mtlDrawArrays(GLMContext glm_ctx, GLenum mode, GLint first, GLsizei count)
{
    // Call the Objective-C method using Objective-C syntax
    [(__bridge id) glm_ctx->mtl_funcs.mtlObj mtlDrawArrays: glm_ctx mode: mode first: first count: count];
}

#pragma mark C interface to mtlDrawElements
-(void) mtlDrawElements: (GLMContext) glm_ctx mode:(GLenum) mode count: (GLsizei) count type: (GLenum) type indices:(const void *)indices
{
    MTLPrimitiveType primitiveType;
    MTLIndexType indexType;

    if ([self processGLState: true] == false)
    {
        return;
    }

    primitiveType = getMTLPrimitiveType(mode);
    assert(primitiveType != 0xFFFFFFFF);

    indexType = getMTLIndexType(type);
    assert(indexType != 0xFFFFFFFF);

    if ([self processElementBuffer] == false)
        return;

    // check all the buffers for metal objects
    Buffer *gl_element_buffer = getElementBuffer(ctx);
    assert(gl_element_buffer);

    id <MTLBuffer>indexBuffer = (__bridge id<MTLBuffer>)(gl_element_buffer->data.mtl_data);
    assert(indexBuffer);

    [_currentRenderEncoder drawIndexedPrimitives:primitiveType indexCount:count indexType:indexType
                                     indexBuffer:indexBuffer indexBufferOffset:0 instanceCount:1];
}

void mtlDrawElements(GLMContext glm_ctx, GLenum mode, GLsizei count, GLenum type, const void *indices)
{
    // Call the Objective-C method using Objective-C syntax
    [(__bridge id) glm_ctx->mtl_funcs.mtlObj mtlDrawElements: glm_ctx mode: mode count: count type: type indices: indices];
}


#pragma mark C interface to mtlDrawRangeElements
-(void) mtlDrawRangeElements: (GLMContext) glm_ctx mode:(GLenum) mode start:(GLuint) start end:(GLuint) end count: (GLsizei) count type: (GLenum) type indices:(const void *)indices
{
    MTLPrimitiveType primitiveType;
    MTLIndexType indexType;

    if ([self processGLState: true] == false)
    {
        return;
    }

    primitiveType = getMTLPrimitiveType(mode);
    assert(primitiveType != 0xFFFFFFFF);

    indexType = getMTLIndexType(type);
    assert(indexType != 0xFFFFFFFF);

    if ([self processElementBuffer] == false)
        return;

    Buffer *gl_element_buffer = getElementBuffer(ctx);
    assert(gl_element_buffer);

    id <MTLBuffer>indexBuffer = (__bridge id<MTLBuffer>)(gl_element_buffer->data.mtl_data);
    assert(indexBuffer);

    // for now lets just ignore the range data and use drawIndexedPrimitives
    //
    // in the future it would be an idea to use temp buffers for large buffers that would wire
    // to much memory down.. like a million point galaxy drawing
    //
    [_currentRenderEncoder drawIndexedPrimitives:primitiveType indexCount:count indexType:indexType
                                     indexBuffer:indexBuffer indexBufferOffset:0 instanceCount:1];
}

void mtlDrawRangeElements(GLMContext glm_ctx, GLenum mode, GLuint start, GLuint end, GLsizei count, GLenum type, const void *indices)
{
    [(__bridge id) glm_ctx->mtl_funcs.mtlObj mtlDrawRangeElements: glm_ctx mode: mode start: start end: end count: count type: type indices: indices];
}


#pragma mark C interface to mtlDrawArraysInstanced
-(void) mtlDrawArraysInstanced: (GLMContext) glm_ctx mode:(GLenum) mode first: (GLint) first count: (GLsizei) count instancecount:(GLsizei) instancecount
{
    MTLPrimitiveType primitiveType;

    if ([self processGLState: true] == false)
    {
        return;
    }

    primitiveType = getMTLPrimitiveType(mode);
    assert(primitiveType != 0xFFFFFFFF);

    [_currentRenderEncoder drawPrimitives:primitiveType vertexStart:first vertexCount:count instanceCount:instancecount];
}

void mtlDrawArraysInstanced(GLMContext glm_ctx, GLenum mode, GLint first, GLsizei count, GLsizei instancecount)
{
    [(__bridge id) glm_ctx->mtl_funcs.mtlObj mtlDrawArraysInstanced: glm_ctx mode: mode first: first count: count instancecount: instancecount];
}


#pragma mark C interface to mtlDrawElementsInstanced
-(void) mtlDrawElementsInstanced: (GLMContext) ctx mode:(GLenum) mode first: (GLint) first count: (GLsizei) count type: (GLenum) type indices:(const void *)indices instancecount:(GLsizei) instancecount
{
}

void mtlDrawElementsInstanced(GLMContext ctx, GLenum mode, GLsizei count, GLenum type, const void *indices, GLsizei instancecount)
{
}


#pragma mark C interface to mtlDrawElementsBaseVertex
-(void) mtlDrawElementsBaseVertex: (GLMContext) ctx mode:(GLenum) mode first: (GLint) first count: (GLsizei) count type: (GLenum) type indices:(const void *)indices basevertex:(GLint) basevertex
{
}

void mtlDrawElementsBaseVertex(GLMContext ctx, GLenum mode, GLsizei count, GLenum type, const void *indices, GLint basevertex)
{
}


#pragma mark C interface to mtlDrawRangeElementsBaseVertex
-(void) mtlDrawRangeElementsBaseVertex: (GLMContext) ctx mode:(GLenum) mode start: (GLuint) start end: (GLuint) end type: (GLenum) type indices:(const void *)indices basevertex:(GLint) basevertex
{
}

void mtlDrawRangeElementsBaseVertex(GLMContext ctx, GLenum mode, GLuint start, GLuint end, GLsizei count, GLenum type, const void *indices, GLint basevertex)
{
}


#pragma mark C interface to mtlDrawElementsInstancedBaseVertex
-(void) mtlDrawElementsInstancedBaseVertex: (GLMContext) ctx mode:(GLenum) mode start: (GLuint) start end: (GLuint) end type: (GLenum) type indices:(const void *)indices instancecount:(GLsizei) instancecount basevertex:(GLint) basevertex
{
}

void mtlDrawElementsInstancedBaseVertex(GLMContext ctx, GLenum mode, GLsizei count, GLenum type, const void *indices, GLsizei instancecount, GLint basevertex)
{
}


#pragma mark C interface to mtlMultiDrawElementsBaseVertex
-(void) mtlMultiDrawElementsBaseVertex: (GLMContext) ctx mode:(GLenum) mode count: (const GLsizei *) count type: (GLenum) type indices:(const void *)indices drawcount:(GLsizei) drawcount basevertex:(const GLint *) basevertex
{
}

void mtlMultiDrawElementsBaseVertex(GLMContext ctx, GLenum mode, const GLsizei *count, GLenum type, const void *const*indices, GLsizei drawcount, const GLint *basevertex)
{
}


#pragma mark C interface to mtlDrawArraysIndirect
-(void) mtlDrawArraysIndirect: (GLMContext) ctx mode:(GLenum) mode indirect: (const void *) indirect
{
}

void mtlDrawArraysIndirect(GLMContext ctx, GLenum mode, const void *indirect)
{
}


#pragma mark C interface to mtlDrawElementsIndirect
-(void) mtlDrawElementsIndirect: (GLMContext) ctx mode:(GLenum) mode first: (GLint) first count: (GLsizei) count type: (GLenum) type indices:(const void *)indices
{
}

void mtlDrawElementsIndirect(GLMContext ctx, GLenum mode, GLenum type, const void *indirect)
{
}


#pragma mark C interface to mtlDrawArraysInstancedBaseInstance
-(void) mtlDrawArraysInstancedBaseInstance: (GLMContext) ctx mode:(GLenum) mode first: (GLint) first count: (GLsizei) count instancecount:(GLsizei) instancecount baseinstance:(GLuint) baseinstance
{
}

void mtlDrawArraysInstancedBaseInstance(GLMContext ctx, GLenum mode, GLint first, GLsizei count, GLsizei instancecount, GLuint baseinstance)
{
}


#pragma mark C interface to mtlDrawElementsInstancedBaseInstance
-(void) mtlDrawElementsInstancedBaseInstance: (GLMContext) ctx mode:(GLenum) mode  count: (GLsizei) count type:(GLenum) type indices:(const void *)indices instancecount:(GLsizei) instancecount baseinstance:(GLuint) baseinstance
{
}

void mtlDrawElementsInstancedBaseInstance(GLMContext ctx, GLenum mode, GLsizei count, GLenum type, const void *indices, GLsizei instancecount, GLuint baseinstance)
{
}


#pragma mark C interface to mtlDrawElementsInstancedBaseVertexBaseInstance
-(void) mtlDrawElementsInstancedBaseVertexBaseInstance: (GLMContext) ctx mode:(GLenum) mode count: (GLsizei) count type:(GLenum) type indices:(const void *)indices
                                                        instancecount:(GLsizei) instancecount basevertex:(GLint) basevertex baseinstance:(GLuint) baseinstance
{
}

void mtlDrawElementsInstancedBaseVertexBaseInstance(GLMContext ctx, GLenum mode, GLsizei count, GLenum type, const void *indices, GLsizei instancecount, GLint basevertex, GLuint baseinstance)
{
}


#pragma mark C interface to context functions

- (void) bindObjFuncsToGLMContext: (GLMContext) glm_ctx
{
    glm_ctx->mtl_funcs.mtlObj = (void *)CFBridgingRetain(self);
    glm_ctx->mtl_funcs.mtlDeleteMTLBuffer = mtlDeleteMTLBuffer;
    glm_ctx->mtl_funcs.mtlDeleteMTLTexture = mtlDeleteMTLTexture;
    glm_ctx->mtl_funcs.mtlGetSync = mtlGetSync;
    glm_ctx->mtl_funcs.mtlWaitForSync = mtlWaitForSync;
    glm_ctx->mtl_funcs.mtlFlush = mtlFlush;
    glm_ctx->mtl_funcs.mtlSwapBuffers = mtlSwapBuffers;
    glm_ctx->mtl_funcs.mtlClearBuffer = mtlClearBuffer;

    glm_ctx->mtl_funcs.mtlBufferSubData = mtlBufferSubData;
    glm_ctx->mtl_funcs.mtlMapUnmapBuffer = mtlMapUnmapBuffer;
    glm_ctx->mtl_funcs.mtlFlushBufferRange = mtlFlushBufferRange;

    glm_ctx->mtl_funcs.mtlGetTexImage = mtlGetTexImage;

    glm_ctx->mtl_funcs.mtlDrawArrays = mtlDrawArrays;
    glm_ctx->mtl_funcs.mtlDrawElements = mtlDrawElements;
    glm_ctx->mtl_funcs.mtlDrawRangeElements = mtlDrawRangeElements;
    glm_ctx->mtl_funcs.mtlDrawArraysInstanced = mtlDrawArraysInstanced;
    glm_ctx->mtl_funcs.mtlDrawElementsInstanced = mtlDrawElementsInstanced;
    glm_ctx->mtl_funcs.mtlDrawElementsBaseVertex = mtlDrawElementsBaseVertex;
    glm_ctx->mtl_funcs.mtlDrawRangeElementsBaseVertex = mtlDrawRangeElementsBaseVertex;
    glm_ctx->mtl_funcs.mtlDrawElementsInstancedBaseVertex = mtlDrawElementsInstancedBaseVertex;
    glm_ctx->mtl_funcs.mtlMultiDrawElementsBaseVertex = mtlMultiDrawElementsBaseVertex;
    glm_ctx->mtl_funcs.mtlDrawArraysIndirect = mtlDrawArraysIndirect;
    glm_ctx->mtl_funcs.mtlDrawElementsIndirect = mtlDrawElementsIndirect;
    glm_ctx->mtl_funcs.mtlDrawArraysInstancedBaseInstance = mtlDrawArraysInstancedBaseInstance;
    glm_ctx->mtl_funcs.mtlDrawElementsInstancedBaseInstance = mtlDrawElementsInstancedBaseInstance;
    glm_ctx->mtl_funcs.mtlDrawElementsInstancedBaseVertexBaseInstance = mtlDrawElementsInstancedBaseVertexBaseInstance;
}

- (void) createMGLRendererAndBindToContext: (GLMContext) glm_ctx view: (NSView *) view
{
    ctx = glm_ctx;

    [self bindObjFuncsToGLMContext: glm_ctx];

    _device = MTLCreateSystemDefaultDevice();
    assert(_device);

    // Create the command queue
    _commandQueue = [_device newCommandQueue];
    assert(_commandQueue);

    _view = view;

    _layer = [[CAMetalLayer alloc] init];
    assert(_layer);

    _layer.device = _device;
    _layer.pixelFormat = ctx->pixel_format.mtl_pixel_format;
    _layer.framebufferOnly = true;
    _layer.frame = view.layer.frame;

    assert([_view layer]);
    [[_view layer] addSublayer: _layer];

    mglDrawBuffer(glm_ctx, GL_FRONT);

    // not sure if this is still needed
    [self newCommandBufferAndRenderEncoder];
    
    glm_ctx->mtl_funcs.mtlView = (void *)CFBridgingRetain(view);
}

@end
