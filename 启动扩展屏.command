#!/bin/zsh
cd "$(dirname "$0")" || exit 1
if [[ -d "build/iPad 扩展屏.app" ]]; then
  open "build/iPad 扩展屏.app"
else
  ./src/build-app.sh && open "build/iPad 扩展屏.app"
fi
