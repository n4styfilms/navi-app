"""Prepare only repository-pinned Boost headers for isolated native host probes."""
import subprocess


def ensure_boost(root):
    boost = root / '3party/boost'
    if not (boost / 'libs/container_hash/include/boost/container_hash/hash.hpp').is_file():
        subprocess.run(['git', '-C', str(root), 'submodule', 'update', '--init', '--depth', '1',
            '3party/boost'], check=True, capture_output=True, text=True, timeout=180)
        headers = ['assert', 'config', 'container_hash', 'core', 'describe', 'mp11',
            'static_assert', 'throw_exception', 'type_traits', 'predef']
        subprocess.run(['git', '-C', str(boost), 'submodule', 'update', '--init', '--depth', '1', '--jobs', '8',
            *('libs/' + name for name in headers)], check=True, capture_output=True, text=True, timeout=180)
    return sorted((boost / 'libs').glob('*/include'))
