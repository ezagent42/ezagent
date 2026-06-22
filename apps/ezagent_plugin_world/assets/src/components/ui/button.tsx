import * as React from "react"
import {cva, type VariantProps} from "class-variance-authority"

import {cn} from "../../lib/utils"

const buttonVariants = cva("world-button", {
  variants: {
    variant: {
      default: "world-button-default",
      primary: "world-button-primary",
      secondary: "world-button-secondary",
      ghost: "world-button-ghost",
      danger: "world-button-danger",
      link: "world-button-link",
    },
    size: {
      default: "",
      sm: "world-button-sm",
      lg: "world-button-lg",
      icon: "world-button-icon",
    },
  },
  defaultVariants: {
    variant: "default",
    size: "default",
  },
})

export interface ButtonProps
  extends React.ButtonHTMLAttributes<HTMLButtonElement>,
    VariantProps<typeof buttonVariants> {}

export const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  ({className, variant, size, ...props}, ref) => {
    return <button className={cn(buttonVariants({variant, size}), className)} ref={ref} {...props} />
  }
)

Button.displayName = "Button"
