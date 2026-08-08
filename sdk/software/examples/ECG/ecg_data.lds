MEMORY
{
  dataset (r) : ORIGIN = 0x1c100000, LENGTH = 3M
}

SECTIONS
{
  .validation_data :
  {
    . = ALIGN(64);
    KEEP(*(.validation_data))
  } >dataset
}
INSERT AFTER .stack;
