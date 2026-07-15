export type PrimaryNavItem = {label: string; href: string}
export type SectionRoot = {label: string; href: string}

export function primaryNavItems(): PrimaryNavItem[]
export function isPrimaryNavActive(path: string | undefined, href: string): boolean
export function sectionRoot(path: string | undefined): SectionRoot | null
export function pageTitleForComponent(component: string | undefined): string
