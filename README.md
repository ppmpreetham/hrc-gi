# HRC Global Illumination - Godot 4 Plugin

A Godot 4 plugin implementing **Holographic Radiance Cascades (HRC)**

> Based on: _"Holographic Radiance Cascades for 2D Global Illumination"_  
> Freeman, Sannikov & Margel (2025) · [arXiv:2505.02041](https://arxiv.org/abs/2505.02041)

## Requirements

- Godot **4.2+**
- **Forward+** renderer (for Vulkan compute shaders)
- GPU with Vulkan support

## Installation

1. Copy the `addons/hrc_gi/` folder into your project's `addons/` directory.
2. Open Godot → **Project → Project Settings → Plugins → HRC Global Illumination → Enable**.
3. Confirm your renderer is **Forward+**: **Project → Project Settings → Rendering → Renderer**.

## Scene Setup

Build this node tree:

```
Node2D                      root node
├── HRCGlobalIllumination   runs the GI computation
│   ├── HRCEmitter          light source
│   └── HRCOccluder         wall or blocker
└── TextureRect             displays the GI output
```

**Adding HRC nodes:** click _Add Child Node_, search "HRC", and the custom types will appear.

## Node API

### HRCGlobalIllumination

| Property           | Description                                                  |
| ------------------ | ------------------------------------------------------------ |
| `Scene Size`       | GI grid resolution - e.g. `512×512`. Power of 2 recommended. |
| `GI Bounces`       | Number of diffuse light bounces (1 = direct lighting only).  |
| `Apply Cross Blur` | Reduces checkerboard artifacts. Leave enabled.               |

### HRCEmitter _(child of HRCGlobalIllumination)_

| Property            | Description                                            |
| ------------------- | ------------------------------------------------------ |
| `Position`          | Pixel position within the GI grid. `(0,0)` = top-left. |
| `Emission Color`    | Color of the light.                                    |
| `Emission Strength` | Brightness. Start around `10.0`.                       |
| `Size`              | Pixel dimensions of the emitter rectangle.             |

### HRCOccluder _(child of HRCGlobalIllumination)_

| Property     | Description                                         |
| ------------ | --------------------------------------------------- |
| `Position`   | Pixel position within the GI grid.                  |
| `Extinction` | Opacity: `0.0` = transparent, `10.0` = fully solid. |
| `Size`       | Pixel dimensions of the occluder rectangle.         |

## Connecting the output

Add a **TextureRect** to your scene (sibling of `HRCGlobalIllumination`, _not_ a child), set it to **Full Rect / Ignore Size / Scale**, then wire it up in a script:

```gdscript
extends Node2D

@onready var hrc = $HRCGlobalIllumination
@onready var display = $TextureRect

func _ready():
    hrc.gi_updated.connect(func(tex): display.texture = tex)
```

## Scripting API

```gdscript
# signal -> fires every frame after GI is computed
signal gi_updated(output_texture: Texture2D)

# the computed GI texture (RGBA16F, same resolution as scene_size)
var gi_texture: ImageTexture

# manually write a pixel into the scene (emission + extinction)
func set_scene_pixel(pos: Vector2i, emission: Color, extinction: float) -> void

# wipe the scene texture
func clear_scene() -> void

# force a recompute next frame (called automatically by HRCEmitter/HRCOccluder)
func mark_dirty() -> void
```

### Procedural scene example

```gdscript
func _ready():
    var hrc = $HRCGlobalIllumination
    hrc.clear_scene()

    # Circular light at center
    for y in range(240, 272):
        for x in range(240, 272):
            if Vector2(x - 256, y - 256).length() < 16:
                hrc.set_scene_pixel(Vector2i(x, y), Color.YELLOW, 0.0)

    # Thin vertical wall
    for y in range(150, 350):
        hrc.set_scene_pixel(Vector2i(350, y), Color.BLACK, 10.0)
```

## Limitations

- Specular/glossy reflections are not supported in the base formulation (diffuse only).
- 3D support is experimental and only practical for small volumes (O(N⁴) memory).
- Light sources smaller than 8× the probe spacing produce aliasing artifacts.

## File Str\*

```
addons/hrc_gi/
├── plugin.cfg
├── plugin.gd
├── scripts/
│   ├── HRCGlobalIllumination.gd   ← main compute orchestrator
│   ├── HRCEmitter.gd              ← light source node
│   ├── HRCOccluder.gd             ← occluder node
│   └── HRCDisplay.gd              ← optional display helper
└── shaders/
    ├── hrc_trace_base.glsl        ← DDA ray marching (cascades 0–2)
    ├── hrc_merge_up.glsl          ← builds T_n acceleration structure
    ├── hrc_merge_down.glsl        ← computes R_n radiance probes
    └── hrc_composite.gdshader     ← combines quadrants + cross-blur
```

## Algorithm

HRC computes fluence F(p) - total light at each point from all directions:

**Phase 1: Trace Base:** Ray-march short intervals (n=0,1,2) using DDA, integrating emission and extinction analytically within each pixel.

**Phase 2: Merge Up:** Build the `T_n` acceleration structure by combining pairs of shorter intervals - approximating long rays without tracing them.

**Phase 3: Merge Down:** Compute `R_n` radiance probes from `R_{n+1}`, splitting each angular cone and merging traced intervals with higher-cascade results.

The world is processed 4 times (rotating 90° each pass) to cover all directions, then summed.

The key improvement over standard Radiance Cascades: probe resolution is only reduced in the direction _parallel_ to the probe's facing, not perpendicular - ensuring sharp shadow edges are always resolved regardless of light distance.

## Credits

Algorithm by **Rouli Freeman** (University of Oxford), **Alexander Sannikov** (Grinding Gear Games), and **Adrian Margel**.
Radiance Cascades is used in production in [Path of Exile 2](https://pathofexile2.com/).
