#!/usr/bin/env python3
"""Build isolated before/after sources and compare renderer frames without changing the checkout."""
import argparse
import fcntl
import io
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

from PIL import Image, ImageChops

REPO = Path(__file__).resolve().parents[1]
FILES = ['src', 'tools', 'shaders', 'justfile', 'odinfmt.json', 'lsan.supp']
CASES = [
    ('cornell_gpu', 'load_cornell_box', {'VEIL_GPU_CULL': '1'}, False),
    ('cornell_cpu', 'load_cornell_box', {'VEIL_GPU_CULL': '0'}, False),
    ('shadows_off', 'load_cornell_box', {'VEIL_NO_SHADOWS': '1'}, False),
    ('transparency', 'load_transparency_test', {'VEIL_GPU_CULL': '1'}, False),
    ('batch_boundary', 'load_cull_batch_boundary', {'VEIL_GPU_CULL': '1'}, False),
    ('single_run_32k', 'load_cull_32k_single_run', {'VEIL_GPU_CULL': '1'}, False),
    ('toggles_resize_skip_overlay', 'load_cornell_box', {'VEIL_GPU_CULL': '1'}, True),
]
DUMP_SIZE = (1280, 720)
REPLAY_SIZE = (960, 540)


def snapshot(dest, ref=None):
    if ref:
        archive = subprocess.check_output(['git', 'archive', ref, *FILES], cwd=REPO)
        with tarfile.open(fileobj=io.BytesIO(archive)) as archive_file:
            archive_file.extractall(dest, filter='data')
    else:
        for name in FILES:
            source = REPO / name
            if source.is_dir():
                shutil.copytree(source, dest / name)
            else:
                shutil.copy2(source, dest / name)
    for name in ['shared', 'assets']:
        (dest / name).symlink_to(REPO / name, target_is_directory=True)


def configure(source, scene, replay):
    text = source.read_text()
    text, count = re.subn(r'\tload_\w+\(&engine, &world\)\n\tif !entity_alive',
                         f'\t{scene}(&engine, &world)\n\tif !entity_alive', text)
    if count != 1:
        raise RuntimeError('Cannot locate the scene call')
    text = text.replace('show_stats := true', 'show_stats := false')
    # Baselines predate the app-side fixed-size dump window; give both trees the same non-resizable window.
    text = text.replace('{.VULKAN, .RESIZABLE}', '{.VULKAN}')
    if replay:
        modern = 'packet.overlay = &overlay' in text
        settings = 'settings' if modern else 'engine.settings'
        injected = f'''
        packet.time = 0
        packet.delta_time = 1.0 / 60.0
        if verify_tick >= 3 do packet.draws[5].world[0, 3] += 0.15
        if verify_tick == 2 {{
            {settings}.gpu_cull = false
            {settings}.shadows = false
        }}
        if verify_tick == 5 do {settings}.shadows = true
        if verify_tick == 6 do {settings}.gpu_cull = true
'''
        if modern:
            injected += '\t\tpacket.settings = settings\n'
            injected += '''
        gfx.overlay_line(packet.overlay, {-0.6, 0.2, 0.5}, {0.6, 0.2, 0.5}, {1, 1, 0, 1}, on_top = true)
        gfx.overlay_text(packet.overlay, &ui_font, "frame contract", 300, 20, {255, 255, 255, 255})
        gfx.overlay_texture_view(packet.overlay, engine.render_targets.hdr_texture, {offset = {-20, 600}, extent = {200, 150}})
'''
        else:
            injected += '''
        gfx.line_renderer_push(&engine.line_renderer, {-0.6, 0.2, 0.5}, {0.6, 0.2, 0.5}, {1, 1, 0, 1}, overlay = true)
        gfx.ui_draw_text(&engine, &ui_font, "frame contract", 300, 20, {255, 255, 255, 255})
        gfx.debug_view_texture(&engine, engine.render_targets.hdr_texture, {offset = {-20, 600}, extent = {200, 150}})
'''
        injected += '''
        if verify_tick == 3 {
            assert(!gfx.engine_render(&engine, &packet, 0, 0))
            log.info("verification: skipped zero-extent frame with changed draw and overlay")
            continue
        }
        if verify_tick == 7 {
            _ = sdl.SetWindowSize(window, 960, 540)
            _ = sdl.SyncWindow(window)
            width, height = 960, 540
            log.info("verification: resize requested 960x540")
        }
'''
        text = text.replace('\tmain_loop: for {', '\tverify_tick := 0\n\tmain_loop: for {\n\t\tverify_tick += 1')
        marker = '\t\tgizmo_draw('
        if text.count(marker) != 1:
            raise RuntimeError('Cannot locate the overlay call')
        offset = text.index(marker)
        text = text[:offset] + injected + text[offset:]
    source.write_text(text)


def capture(worktree, prefix, env, frames):
    with (prefix.parent / (prefix.name + '.build.log')).open('w') as build_log:
        subprocess.run(['just', '--tempdir', '/tmp', 'build-debug'], cwd=worktree,
                       stdout=build_log, stderr=subprocess.STDOUT, check=True, timeout=180)
    run_env = os.environ | {'VEIL_STATS': '0', 'VEIL_PARTICLES': '0',
                           'VEIL_DUMP_FRAME': f'{prefix}:{frames}', 'VEIL_PICK_TEST': '640,360'} | env
    if run_env.get('VEIL_GPU_CULL', '1') == '1':
        run_env['VEIL_GPU_CULL_VALIDATE'] = '1'
    with (prefix.parent / (prefix.name + '.log')).open('w') as run_log:
        subprocess.run(['bash', 'tools/run-debug.sh', './build/veil-debug'], cwd=worktree,
                       env=run_env, stdout=run_log, stderr=subprocess.STDOUT, check=True, timeout=180)
    log = prefix.with_suffix('.log').read_text()
    if re.search(r'\[(?:ERROR|WARN)|AddressSanitizer|LeakSanitizer|Assertion Failure', log):
        raise RuntimeError(f'Runtime diagnostics in {prefix}.log')
    if run_env.get('VEIL_GPU_CULL_VALIDATE') == '1':
        if not re.search(r'GPU culling validation:.*mismatches=0 false_negatives=0.*structural=0', log):
            raise RuntimeError(f'Missing clean cull validation in {prefix}.log')
    return log


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', default='35fa6d87b96321954bb381d7b0f380c77c2e0f5b')
    parser.add_argument('--out', type=Path, default=REPO / '.scratch/renderer-architecture/verification')
    parser.add_argument('--case', choices=[c[0] for c in CASES])
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    baseline_sha = subprocess.check_output(['git', 'rev-parse', args.baseline], cwd=REPO, text=True).strip()
    results = {'baseline_sha': baseline_sha, 'current_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPO, text=True).strip(),
               'current_diff': subprocess.check_output(['git', 'diff', '--stat'], cwd=REPO, text=True), 'cases': []}
    # Use the repository's established fixed-size, unfocused dump-window policy.
    if shutil.which('hyprctl'):
        subprocess.run(['hyprctl', 'eval', 'hl.window_rule({ name = "veil-dump", match = { class = "^(veil)$" }, float = true, size = "1280 720", no_focus = true })'], check=True, stdout=subprocess.DEVNULL)
    with open('/tmp/veil-dump.lock', 'w') as lock, tempfile.TemporaryDirectory(prefix='veil-frame-check-') as temp:
        fcntl.flock(lock, fcntl.LOCK_EX)
        before, after = Path(temp) / 'before', Path(temp) / 'after'
        before.mkdir()
        after.mkdir()
        snapshot(before, baseline_sha)
        snapshot(after)
        results['current_source_sha256'] = {str(path.relative_to(after)): hashlib.sha256(path.read_bytes()).hexdigest() for base in [after / 'src', after / 'tools/frame_checks'] for path in sorted(base.rglob('*.odin'))}
        originals = {tree: (tree / 'src/main.odin').read_text() for tree in [before, after]}
        for name, scene, env, replay in CASES:
            if args.case and name != args.case:
                continue
            count = 9 if replay else 3
            logs = []
            for tree, version in [(before, 'before'), (after, 'after')]:
                path = tree / 'src/main.odin'
                path.write_text(originals[tree])
                configure(path, scene, replay)
                logs.append(capture(tree, args.out / f'{name}_{version}', env, count))
            sizes = []
            for i in range(count):
                first = Image.open(args.out / f'{name}_before_{i:03}.png').convert('RGBA')
                second = Image.open(args.out / f'{name}_after_{i:03}.png').convert('RGBA')
                if first.size != second.size or first.tobytes() != second.tobytes():
                    if first.size == second.size:
                        ImageChops.difference(first, second).save(args.out / f'{name}_diff_{i:03}.png')
                    raise RuntimeError(f'{name} frame {i}: pixels differ ({first.size} vs {second.size})')
                sizes.append(first.size)
            # The window must keep its fixed size (the compositor can ignore it); the replay resizes once on purpose.
            allowed = {DUMP_SIZE, REPLAY_SIZE} if replay else {DUMP_SIZE}
            unexpected = sorted(set(sizes) - allowed)
            if unexpected:
                raise RuntimeError(f'{name}: captured extents {unexpected}, expected only {sorted(allowed)}; '
                                   'the compositor resized the dump window (is it tiling it?)')
            if replay:
                if not all('skipped zero-extent' in log and 'resize requested' in log for log in logs):
                    raise RuntimeError('Replay did not exercise skip and resize')
                if (960, 540) not in sizes:
                    raise RuntimeError('Replay never rendered at the resized extent')
            # draw ids differ between builds (slot vs slot - 1); compare the rest of the line
            picks = [[re.sub(r'-> draw \d+', '-> draw', p) for p in re.findall(r'pick test .*', log)] for log in logs]
            if picks[0] != picks[1]:
                raise RuntimeError(f'{name}: picking changed')
            for i in range(count):
                if (args.out / f'{name}_before_{i:03}.png').read_bytes() != (args.out / f'{name}_after_{i:03}.png').read_bytes():
                    raise RuntimeError(f'{name} frame {i}: PNG bytes differ despite equal pixels')
            results['cases'].append({'name': name, 'frames': count, 'pixel_diff': 0, 'png_bytes_equal': True, 'extents': sizes, 'diagnostics': 'clean', 'picking': 'equal'})
            results['png_files_byte_identical'] = sum(case['frames'] for case in results['cases'])
            (args.out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
            print(f'PASS {name}: {count} pixel-identical frames, clean debug run', flush=True)


if __name__ == '__main__':
    main()
