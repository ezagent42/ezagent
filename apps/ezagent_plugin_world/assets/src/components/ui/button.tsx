import * as React from "react"
import {cva, type VariantProps} from "class-variance-authority"

import {cn} from "../../lib/utils"

const buttonVariants = cva("world-button", {
  variants: {
    variant: {
      default: "world-button-default",
      secondary: "world-button-secondary",
      ghost: "world-button-ghost",
    },
  },
  defaultVariants: {
    variant: "default",
  },
})

export interface ButtonProps
  extends React.ButtonHTMLAttributes<HTMLButtonElement>,
    VariantProps<typeof buttonVariants> {}

export const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  ({className, variant, ...props}, ref) => {
    return <button className={cn(buttonVariants({variant}), className)} ref={ref} {...props} />
  }
)

Button.displayName = "Button"
