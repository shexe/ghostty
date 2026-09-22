#include "common.glsl"

// Position the origin to the upper left
layout(origin_upper_left) in vec4 gl_FragCoord;

// Must declare this output for some versions of OpenGL.
layout(location = 0) out vec4 out_FragColor;

layout(binding = 1, std430) readonly buffer bg_cells {
    uint cells[];
};

vec4 cell_bg() {
    uvec2 grid_size = unpack2u16(grid_size_packed_2u16);
    // Account for the sub-cell scroll translation of the grid (smooth
    // scrolling) so the cell lookup matches the visually translated grid.
    vec2 grid_px = gl_FragCoord.xy - grid_padding.wx - vec2(0.0, grid_offset_y);
    ivec2 grid_pos = ivec2(floor(grid_px / cell_size));
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    vec4 bg = vec4(0.0);

    // Region scroll animation: inside an animating rectangle the content
    // is drawn shifted, so look the cell up where it is drawn from. Past
    // the region's own rows that is a ghost row sliding out, if one is
    // still there, and otherwise nothing: the surface background.
    int region = region_of(grid_px);
    if (region >= 0) {
        vec4 r = region_rect[region];
        float y = grid_px.y - region_shift[region].x;
        int row = int(floor(y / cell_size.y));
        int col = clamp(int(floor(grid_px.x / cell_size.x)), 0, int(grid_size.x) - 1);
        int cols = int(grid_size.x);
        if (y >= r.y && y < r.w) {
            row = clamp(row, 0, int(grid_size.y) - 1);
            return load_color(unpack4u8(cells[row * cols + col]), use_linear_blending);
        }
        for (uint k = 0u; k < anim_counts.y; k++) {
            ivec4 ghost = ghost_rows[k];
            if (ghost.x == region && ghost.y == row) {
                return load_color(
                        unpack4u8(cells[(int(anim_counts.z) + int(k)) * cols + col]),
                        use_linear_blending
                    );
            }
        }
        return bg;
    }

    // Clamp x position, extends edge bg colors in to padding on sides.
    if (grid_pos.x < 0) {
        if ((padding_extend & EXTEND_LEFT) != 0) {
            grid_pos.x = 0;
        } else {
            return bg;
        }
    } else if (grid_pos.x > grid_size.x - 1) {
        if ((padding_extend & EXTEND_RIGHT) != 0) {
            grid_pos.x = int(grid_size.x) - 1;
        } else {
            return bg;
        }
    }

    // Clamp y position if we should extend, otherwise discard if out of
    // bounds. The extra rows beyond the viewport edges are valid when
    // rendered: the two rows below the viewport are stored at grid rows
    // grid_size.y and grid_size.y + 1 (natural positions) and the row
    // above at grid_size.y + 2.
    if (grid_pos.y < 0) {
        if (grid_pos.y == -1 && (grid_extra_rows & EXTRA_ABOVE) != 0) {
            grid_pos.y = int(grid_size.y) + 2;
        } else if ((padding_extend & EXTEND_UP) != 0) {
            grid_pos.y = 0;
        } else {
            return bg;
        }
    } else if (grid_pos.y > grid_size.y - 1) {
        if (grid_pos.y == int(grid_size.y) && (grid_extra_rows & EXTRA_BELOW) != 0) {
            // The row below the viewport; stored at its natural index.
        } else if (grid_pos.y == int(grid_size.y) + 1 && (grid_extra_rows & EXTRA_BELOW2) != 0) {
            // The second row below the viewport; stored at its natural index.
        } else if ((padding_extend & EXTEND_DOWN) != 0) {
            grid_pos.y = int(grid_size.y) - 1;
        } else {
            return bg;
        }
    }

    // Load the color for the cell.
    vec4 cell_color = load_color(
            unpack4u8(cells[grid_pos.y * grid_size.x + grid_pos.x]),
            use_linear_blending
        );

    return cell_color;
}

void main() {
    out_FragColor = cell_bg();
}
