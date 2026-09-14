#!/bin/bash
# Git push script for myclaude repository

set -e

echo "Setting up remote origin..."
git remote add origin https://github.com/S-V-J/myclaude.git

echo "Remote configured:"
git remote -v

echo "Pushing to origin main..."
git push -u origin main

echo "Push complete!"