name: Deploy DineQR to GitHub Pages

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read
  pages: write
  id-token: write

concurrency:
  group: pages
  cancel-in-progress: true

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Get the source
        uses: actions/checkout@v4

      - name: Set up Node.js
        uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: npm

      - name: Configure GitHub Pages
        uses: actions/configure-pages@v5

      - name: Configure the website address
        shell: bash
        run: |
          REPOSITORY_NAME="${GITHUB_REPOSITORY#*/}"
          if [[ "$REPOSITORY_NAME" == *.github.io ]]; then
            BASE_PATH=""
          else
            BASE_PATH="/$REPOSITORY_NAME"
          fi
          echo "NEXT_PUBLIC_BASE_PATH=$BASE_PATH" >> "$GITHUB_ENV"
          echo "NEXT_PUBLIC_SITE_URL=https://${GITHUB_REPOSITORY_OWNER}.github.io" >> "$GITHUB_ENV"
          echo "NEXT_PUBLIC_SUPABASE_URL=https://yalfwsqfnzunecnmxajq.supabase.co" >> "$GITHUB_ENV"
          echo "NEXT_PUBLIC_SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InlhbGZ3c3Fmbnp1bmVjbm14YWpxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODEyNjYwNjUsImV4cCI6MjA5Njg0MjA2NX0.277WcudAYbzA5sG4UpFc9ta8_IVDyn0zxnS85Q35Urc" >> "$GITHUB_ENV"

      - name: Install dependencies
        run: npm ci

      - name: Build static website
        run: |
          npm run build
          touch out/.nojekyll

      - name: Upload website
        uses: actions/upload-pages-artifact@v4
        with:
          path: out

  deploy:
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    runs-on: ubuntu-latest
    needs: build
    steps:
      - name: Publish website
        id: deployment
        uses: actions/deploy-pages@v4
