<?php

declare(strict_types=1);

use Aeliot\TodoRegistrar\Config;
use Aeliot\TodoRegistrar\Service\File\Finder;
use Aeliot\TodoRegistrarContracts\RegistrarFactoryInterface;
use Aeliot\TodoRegistrarContracts\RegistrarInterface;
use Aeliot\TodoRegistrarContracts\TodoInterface;

class StubRegistrar implements RegistrarInterface
{
    private int $count = 0;

    public function register(TodoInterface $todo): string
    {
        return '#' . (++$this->count);
    }

    public function __destruct()
    {
        file_put_contents('/code/.benchmark-stats.json', json_encode([
            'count' => $this->count,
            'peak_memory_bytes' => memory_get_peak_usage(true),
        ]));
    }
}

class StubRegistrarFactory implements RegistrarFactoryInterface
{
    public function create(array $config): RegistrarInterface
    {
        return new StubRegistrar();
    }
}

return (new Config())
    ->setFinder(
        (new Finder())
            ->in('/code')
            ->exclude(['vendor'])
            ->notPath('/\/[Ff]ixtures\//')
    )
    ->setRegistrar(new StubRegistrarFactory(), []);
