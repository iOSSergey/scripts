#!/usr/bin/env bash
set -euo pipefail

mkdir -p ~/dev

if [ ! -d ~/dev/scripts/.git ]; then
  git clone https://github.com/iOSSergey/scripts.git ~/dev/scripts
else
  git -C ~/dev/scripts pull
fi

find ~/dev/scripts -type f -name "*.sh" -exec chmod +x {} \;

echo "Scripts installed"
