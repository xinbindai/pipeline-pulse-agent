/** @type {import('next').NextConfig} */
const nextConfig = {
  // Emit a self-contained server with only the traced node_modules — much
  // smaller runtime image (faster Cloud Run image pull / revision creation).
  output: "standalone",
};

export default nextConfig;
