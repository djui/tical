/** Wrangler bundles .pem files as text; see `rules` in wrangler.jsonc. */
declare module "*.pem" {
  const text: string;
  export default text;
}
