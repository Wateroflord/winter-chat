#!/bin/bash
cd "$(dirname "$0")"
chmod +x winter-chat-server livekit-server 2>/dev/null
./winter-chat-server
